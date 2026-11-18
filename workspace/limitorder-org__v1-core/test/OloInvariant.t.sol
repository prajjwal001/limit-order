// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {U512, Wide} from "./utils/Wide.sol";
import {OloBook} from "../src/OloBook.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {PoolWord} from "../src/OloTypes.sol";

using MarketLib for MarketWord;

/// One market of the invariant suite: its config word, tokens, the band of ticks its makers use (around a decade
/// boundary, on its spacing) and the sizes its orders take (10^lo .. 10^hi base wei, times 1 to 999).
struct Mkt {
    MarketWord c;
    MockERC20 b;
    MockERC20 q;
    uint256 center;
    uint256 spread;
    uint256 spacing;
    uint256 lo;
    uint256 hi;
    uint256 ppm;
}

/// What the invariant suite's fuzzer calls: every operation of the OLO EVM contract by three actors on seven markets,
/// each step bounded into something the contract may accept (and often refuse: a refusal is not a finding, so every
/// call is tried and its revert swallowed). A revert inside a handler does not fail an invariant run (fail_on_revert is
/// off), so what a successful take must satisfy is checked here and counted in `violations`, which an invariant holds
/// at zero:
///   - base mode fills at most its amount; quote mode pays (a buy) or receives (a sell) at most its amount;
///   - fill-or-kill leaves at most maxLeft of the amount;
///   - the quote is the fills' exact sum rounded once in the contract's favour (a buy up, a sell down) and the fee is
///   the
///     exact sum's, rounded up (recomputed from the Take event's records and the orders' ticks before the take, in
///     512-bit integers);
///   - the taker's account or wallet moves by exactly what the take returns.
contract OloHandler is Test {
    using Wide for U512;

    /// Where the handler's orders start: positions 0 .. NPOS - 1. A place probes up to 2 further positions and a
    /// takeThenRest's rest up to MAX_PROBES, so an order lands anywhere in 0 .. NSCAN - 1, the positions every scan
    /// reads (the take lists, the cancels and claims, the solvency sum, everyone leaving); an order that lands past
    /// them is flagged.
    uint256 internal constant NPOS = 8;
    uint256 internal constant MAX_PROBES = 3;
    uint256 public constant NSCAN = NPOS + MAX_PROBES;
    uint256 internal constant NSLOT = 2;

    OloBook public book;
    Mkt[] internal mkts; // every version of every market, the listings first
    mapping(uint32 marketId => uint256) internal latest; // each market's current version, its index in `mkts`
    address[3] public actors;
    MockERC20[] internal tokens;

    uint256 public violations;
    uint256 public mixedSeen; // batch calls on a slot holding both sides (live bids and live asks)
    uint256 public sideFaults; // slot words with bit 0 or bits 250-255 set, or an empty sub-order with a side bit
    string public lastViolation;
    mapping(bytes32 => uint256) public calls; // per action: attempts
    mapping(bytes32 => uint256) public oks; // per action: successes
    uint256 public quoteTakes; // successful quote-mode takes that filled
    uint256 public stopsBelowAmount; // successful quote-mode takes that left something
    // a version at a fee of 100%: sells refused SellBelowFee, sells that filled nothing and succeeded
    uint256 public fullFeeSellRefusals;
    uint256 public fullFeeEmptySells;
    // a version at a fee of 990,000 ppm or more: buys that filled, and sells that filled below 100%
    uint256 public highFeeBuys;
    uint256 public highFeeSells;
    uint256 public budgetRefusals; // quote-mode sells whose budget passed 2^126, refused AmountOverflow
    mapping(bytes32 => uint256) public olderOks; // per action: successes in an older version than its market's current
    uint256 public keyHeaderOks; // successful multicalls under a header that is a key K
    uint256 public probedPast; // orders (a place's, a takeThenRest's rest) that landed past the start range, NPOS up
    // successful takes that filled a batch sub-order, by key: buy, sell, base, quote, older
    mapping(bytes32 => uint256) public batchFills;
    // successful batch operations that paid a sub-order's fills (a claim, or a cancel, replace or modify that settled
    // it), read from the slot's words before and after: all, older
    mapping(bytes32 => uint256) public batchSettles;

    constructor(OloBook book_, address[3] memory actors_, MockERC20[] memory tokens_) {
        book = book_;
        actors = actors_;
        tokens = tokens_;
    }

    function addMarket(Mkt memory m) external {
        _push(m);
    }

    /// A version joins the markets acted on, the current one of its market.
    function _push(Mkt memory m) internal {
        latest[m.c.marketId()] = mkts.length;
        mkts.push(m);
    }

    function marketCount() external view returns (uint256) {
        return mkts.length;
    }

    function market(uint256 i) external view returns (Mkt memory) {
        return mkts[i];
    }

    function acceptOwnership() external {
        book.acceptOwnership();
    }

    // ---------------------------------------------------------------- helpers

    function _flag(string memory why) internal {
        ++violations;
        lastViolation = why;
    }

    /// A market to act on: any version of any market, three times in four its market's current version (older
    /// versions only drain, and most calls rest or move orders).
    function _mkt(uint256 r) internal view returns (Mkt memory m) {
        m = mkts[r % mkts.length];
        if ((r >> 200) % 4 != 0) m = mkts[latest[m.c.marketId()]];
    }

    /// A market for a call that drains (a cancel, a claim, a take, a batch cancel or claim): any version of any market,
    /// half the time its market's current version, so the older versions' orders fill and settle too.
    function _mktDrain(uint256 r) internal view returns (Mkt memory m) {
        m = mkts[r % mkts.length];
        if ((r >> 200) % 2 != 0) m = mkts[latest[m.c.marketId()]];
    }

    function _actor(uint256 r) internal view returns (address) {
        return actors[r % 3];
    }

    /// Whether `m` is its market's current version.
    function _current(Mkt memory m) internal view returns (bool) {
        return MarketWord.unwrap(m.c) == MarketWord.unwrap(mkts[latest[m.c.marketId()]].c);
    }

    /// A position of `m`: half the time the first from a random start holding a live order (with fills to claim when
    /// `filled`), else (or when there is none) the random one.
    function _pickPos(Mkt memory m, uint256 r, bool filled) internal view returns (uint32) {
        uint256 start = r % NSCAN;
        if ((r >> 8) % 2 == 0) {
            for (uint256 k; k < NSCAN; ++k) {
                uint256 word = book.orderWord(m.c, uint32((start + k) % NSCAN));
                uint256 have = filled ? (word >> 63) & ((1 << 30) - 1) : (word >> 33) & ((1 << 60) - 1);
                if (have != 0) return uint32((start + k) % NSCAN);
            }
        }
        return uint32(start);
    }

    /// Half the time the owner of the order in `pos` of `m` (when one is live there), else a random actor: a cancel or
    /// a claim that names its own order runs.
    function _ownerOr(Mkt memory m, uint32 pos, uint256 r) internal view returns (address) {
        uint256 word = book.orderWord(m.c, pos);
        if (r % 2 == 0 && (word >> 33) & ((1 << 60) - 1) != 0) return address(uint160(word >> 96));
        return _actor(r >> 1);
    }

    /// A maker tick in the market's band, on its spacing.
    function _tick(Mkt memory m, uint256 r) internal pure returns (uint256 t) {
        t = m.center - m.spread + r % (2 * m.spread + 1);
        t -= t % m.spacing;
    }

    function _amount(Mkt memory m, uint256 r) internal pure returns (uint256) {
        return (1 + r % 999) * 10 ** (m.lo + (r >> 16) % (m.hi - m.lo + 1));
    }

    function _settleFlags(uint256 r) internal pure returns (uint8) {
        uint256 k = r % 4;
        return k == 1 ? 0x02 : k == 2 ? 0x04 : 0;
    }

    function _try(bytes32 action, address who, bytes memory data) internal returns (bool ok, bytes memory ret) {
        ++calls[action];
        vm.prank(who);
        (ok, ret) = address(book).call(data);
        if (ok) ++oks[action];
    }

    // ---------------------------------------------------------------- makers

    function place(uint256 r, uint256 r2) external {
        Mkt memory m = _mkt(r);
        bool bid = (r >> 8) & 1 == 1;
        uint8 flags = _settleFlags(r >> 12) | uint8(((r >> 16) % MAX_PROBES) << 4);
        (bool ok, bytes memory ret) = _try(
            "place",
            _actor(r >> 20),
            abi.encodeCall(
                book.place,
                (
                    OloOps.key(m.c),
                    OloOps.placeW(bid, _tick(m, r2), _amount(m, r2 >> 40), uint32((r >> 24) % NPOS), flags)
                )
            )
        );
        if (ok) {
            (uint256 orderId,) = abi.decode(ret, (uint256, uint256));
            _landed(uint32(orderId));
        }
    }

    /// Where an order landed: past NSCAN no scan reads it (flagged); past the start range, a probe's landing.
    function _landed(uint32 pos) internal {
        if (pos >= NSCAN) _flag("an order landed past the positions scanned");
        if (pos >= NPOS) ++probedPast;
    }

    function cancel(uint256 r) external {
        Mkt memory m = _mktDrain(r);
        uint32 pos = _pickPos(m, r >> 16, false);
        (bool ok,) = _try(
            "cancel",
            _ownerOr(m, pos, r >> 8),
            abi.encodeCall(book.cancel, (OloOps.key(m.c), OloOps.tagW(m.c, OloOps.posW(pos, 0))))
        );
        if (ok && !_current(m)) ++olderOks["cancel"];
    }

    function claim(uint256 r) external {
        Mkt memory m = _mktDrain(r);
        uint32 pos = _pickPos(m, r >> 16, true);
        (bool ok,) = _try(
            "claim",
            _ownerOr(m, pos, r >> 8),
            abi.encodeCall(
                book.claim, (OloOps.key(m.c), OloOps.tagW(m.c, OloOps.posW(pos, uint8(_settleFlags(r >> 24) & 0x02))))
            )
        );
        if (ok && !_current(m)) ++olderOks["claim"];
    }

    function modify(uint256 r, uint256 r2) external {
        Mkt memory m = _mkt(r);
        _try(
            "modify",
            _actor(r >> 8),
            abi.encodeCall(
                book.modify,
                (
                    OloOps.key(m.c),
                    OloOps.tagW(
                        m.c,
                        OloOps.modifyW(
                            uint32((r >> 16) % NSCAN), _tick(m, r2), _amount(m, r2 >> 40), _settleFlags(r >> 24)
                        )
                    )
                )
            )
        );
    }

    /// A batch operation: a post, replace or modify of one to four orders, a cancel or a claim, on one of two slots.
    function batch(uint256 r, uint256 r2) external {
        uint8 kind = uint8((r >> 8) % 5);
        Mkt memory m = kind == OloOps.CANCEL || kind == OloOps.CLAIM ? _mktDrain(r) : _mkt(r);
        bool bid = (r >> 12) & 1 == 1;
        uint16 slot = uint16((r >> 16) % NSLOT);
        uint8 flags = _settleFlags(r >> 20);
        uint8 mask = uint8(1 + (r >> 24) % 15);
        uint256[4] memory o;
        for (uint256 i; i < 4; ++i) {
            uint256 ri = uint256(keccak256(abi.encode(r2, i)));
            if (ri % 5 != 0) o[i] = OloOps.sub(_tick(m, ri), _amount(m, ri >> 40));
        }
        address who = _actor(r >> 32);
        // the sides (params 136-139): every order on `bid`'s side half the time, else each its own, so slots holding
        // both sides and modifies turning a live sub-order run
        uint8 sides = (r2 >> 255) == 1 ? uint8(r2 >> 248) & 0xf : (bid ? 0xf : 0);
        // a cancel or a claim, half the time by an actor with sub-orders in the slot (a claim: with fills to pay),
        // every one named: the settles run
        for (uint256 i; i < 3 && (kind == OloOps.CANCEL || kind == OloOps.CLAIM) && (r >> 40) % 2 == 0; ++i) {
            (uint256 word, uint256 set) = book.batchOf(m.c, _actor((r >> 32) + i), slot);
            if (word >> 2 == 0 || (kind == OloOps.CLAIM && _filledMask(word, set) == 0)) continue;
            (who, mask) = (_actor((r >> 32) + i), 0xf);
            break;
        }
        _batchRun(m, kind, slot, flags, mask, o, who, sides);
    }

    /// A batch operation as given, on the version `mkts[mi]` names (a post rests in its market's current one): the
    /// counter examples' entry (test only; the fuzzer calls `batch`).
    function batchExact(
        uint256 mi,
        uint8 kind,
        bool bid,
        uint16 slot,
        uint8 flags,
        uint8 mask,
        uint256[4] memory o,
        address who
    ) external {
        _batchRun(mkts[mi], kind, slot, flags, mask, o, who, bid ? 0xf : 0);
    }

    function _batchRun(
        Mkt memory m,
        uint8 kind,
        uint16 slot,
        uint8 flags,
        uint8 mask,
        uint256[4] memory o,
        address who,
        uint8 sides
    ) internal {
        (uint256 word0, uint256 set0) = book.batchOf(m.c, who, slot);
        uint256[3] memory w = kind == OloOps.CANCEL || kind == OloOps.CLAIM
            ? OloOps.maskW(kind, slot, flags, mask)
            : OloOps.withSides(OloOps.batchW(kind, false, slot, flags, mask, o), sides);
        if (_mixed(word0)) ++mixedSeen;
        (bool ok,) = _try("batch", who, OloOps.batchCalldata(book.manageBatchSubs.selector, m.c, w));
        // a post names no version (it rests in the current one); a cancel or a claim settles the version it names
        if (ok && !_current(m) && (kind == OloOps.CANCEL || kind == OloOps.CLAIM)) ++olderOks["batch"];
        // fills paid: a sub-order of this version's slot with fills before the call and none after (emptied, claimed
        // down to its open units, or rested again). Only the maker's operation moves a base, so nothing else clears
        // them; a post in another version, or a cancel or modify whose mask leaves them out, leaves them as they were
        (uint256 word1, uint256 set1) = book.batchOf(m.c, who, slot);
        _sideCheck(word1);
        if (ok && _filledMask(word0, set0) & ~_filledMask(word1, set1) != 0) {
            ++batchSettles["all"];
            if (!_current(m)) ++batchSettles["older"];
        }
    }

    /// The live sub-orders of a slot's main word, as a mask (bit j: its 61 bits not zero; one filled to no open units
    /// is live, its side kept, until a settle empties it).
    function _liveMask(uint256 word) internal pure returns (uint256 live) {
        for (uint256 j; j < 4; ++j) {
            if ((word >> (2 + 61 * j)) & ((1 << 61) - 1) != 0) live |= 1 << j;
        }
    }

    /// A slot holding both sides: among its live sub-orders, some bids (side bit D_j set) and some asks.
    function _mixed(uint256 word) internal pure returns (bool) {
        uint256 live = _liveMask(word);
        uint256 bids = (word >> 246) & live;
        return bids != 0 && bids != live;
    }

    /// A main word's side bits as the contract keeps them: bit 0 and bits 250-255 zero, and no side on an empty
    /// sub-order (the word's sides are its live bids).
    function _sideCheck(uint256 word) internal {
        if (word & 1 != 0 || word >> 250 != 0) {
            ++sideFaults;
            _flag("a batch word with bit 0 or bits 250-255 set");
        }
        if ((word >> 246) & ~_liveMask(word) != 0) {
            ++sideFaults;
            _flag("an empty sub-order with a side bit");
        }
    }

    /// The sub-orders of a slot's words with fills to pay, as a mask (bit j: live, its base above its open units).
    function _filledMask(uint256 word, uint256 set) internal pure returns (uint256 mask) {
        for (uint256 j; j < 4; ++j) {
            uint256 sub = (word >> (2 + 61 * j)) & ((1 << 61) - 1);
            if (sub != 0 && (set >> (30 * j)) & ((1 << 30) - 1) != sub >> 31) mask |= 1 << j;
        }
    }

    /// A multicall on one market, settled by random flags. In the market's current version: a PLACE in a position, a
    /// MODIFY of it, and now and then its CANCEL, with a DEPOSIT of the quote token before them, under a header naming
    /// the version by its key K half the time, else by its C. In an older version, named by its C (K names only the
    /// current one): a CANCEL or a CLAIM of the position, mostly by its order's owner, which settles there.
    function multicall(uint256 r, uint256 r2) external {
        Mkt memory m = _mkt(r);
        bool current = _current(m);
        uint32 pos = current ? uint32((r >> 8) % NPOS) : _pickPos(m, r >> 8, (r >> 20) & 1 == 1);
        bool byKey = current && (r >> 44) & 1 == 0;
        bytes memory ops;
        address who = _actor(r >> 36);
        if (current) {
            ops = bytes.concat(
                OloOps.deposit(book.tokenId(address(m.q)), uint128(1 + (r2 >> 200) % 1e12)),
                OloOps.place(0, _tick(m, r2), (r >> 16) & 1 == 1, _amount(m, r2 >> 40), pos),
                OloOps.modify(0, pos, _tick(m, r2 >> 80), _amount(m, r2 >> 120))
            );
            if ((r >> 20) & 1 == 1) ops = bytes.concat(ops, OloOps.cancel(0, pos));
        } else {
            ops = (r >> 20) & 1 == 1 ? OloOps.claim(0, pos) : OloOps.cancel(0, pos);
            who = _ownerOr(m, pos, r >> 36);
        }
        bytes memory hdr = OloOps.header(byKey ? OloOps.key(m.c) : m.c);
        (bool ok,) =
            _try("multicall", who, abi.encodeCall(book.multicall, (_settleFlags(r >> 40), bytes.concat(hdr, ops))));
        if (ok && byKey) ++keyHeaderOks;
        if (ok && !current) ++olderOks["multicall"];
    }

    // ---------------------------------------------------------------- accounts and fees

    function deposit(uint256 r, uint256 amount) external {
        MockERC20 t = tokens[r % tokens.length];
        address a = _actor(r >> 8);
        amount = bound(amount, 1, 1e30);
        _try("deposit", a, abi.encodeCall(book.deposit, (address(t), amount)));
    }

    function withdraw(uint256 r, uint256 amount) external {
        MockERC20 t = tokens[r % tokens.length];
        address a = _actor(r >> 8);
        uint256 held = book.balanceOf(book.tokenId(address(t)), a);
        amount = held == 0 ? 1 : bound(amount, 1, held);
        _try("withdraw", a, abi.encodeCall(book.withdraw, (address(t), amount)));
    }

    /// The owner changes a market's share (`setMarketMakerShare`): its next version, added to the markets the handler
    /// acts on (the version before stays in the list: its orders still fill, cancel and claim at its own share, and a
    /// place there names the market by its key and rests in the current version). From a current version only, as
    /// `setFee`; the share it has is no change.
    function setShare(uint256 r) external {
        Mkt memory m = _mkt(r);
        ++calls["share"];
        uint16 bps = uint16((r >> 8) % 10_001);
        (,, bool active) = book.makerShareOf(m.c);
        if (!active || bps == m.c.makerBps()) return;
        book.setMarketMakerShare(m.c.marketId(), bps);
        ++oks["share"];
        m.c = book.configOf(m.c.marketId());
        _push(m);
    }

    function collectFees(uint256 r) external {
        _try("collect", actors[0], abi.encodeCall(book.collectFees, (address(tokens[r % tokens.length]))));
    }

    /// A flash by an actor, whose code (FlashActor) runs the program the handler builds: nothing; a loan of the tokens
    /// (withdrawn, then deposited back); the credit withdrawn and kept, so the actor's own balance repays it or the
    /// flash reverts; or a pool order of a market trading the token, escrowed on the credit and cancelled. Repaid or
    /// not, the invariants hold after it.
    function flash(uint256 r, uint256 r2) external {
        MockERC20 t = tokens[r % tokens.length];
        address a = _actor(r >> 8);
        uint256 amount = bound(r2, 1, 1e30);
        uint256 kind = (r >> 40) % 4;
        address[] memory targets = new address[](2);
        bytes[] memory calls = new bytes[](2);
        uint256 n;
        if (kind == 1 || kind == 2) {
            targets[n] = address(book);
            calls[n++] = abi.encodeCall(book.withdraw, (address(t), amount));
            if (kind == 1) {
                targets[n] = address(book);
                calls[n++] = abi.encodeCall(book.deposit, (address(t), amount));
            }
        } else if (kind == 3) {
            // the current version of a market trading the token: a bid escrows its quote, an ask its base
            for (uint256 k; k < mkts.length; ++k) {
                Mkt memory m = mkts[latest[mkts[((r >> 48) + k) % mkts.length].c.marketId()]];
                if (address(m.b) != address(t) && address(m.q) != address(t)) continue;
                uint32 pos = uint32((r >> 24) % NPOS);
                targets[0] = address(book);
                calls[0] = abi.encodeCall(
                    book.place,
                    (
                        OloOps.key(m.c),
                        OloOps.placeW(address(m.q) == address(t), _tick(m, r2 >> 8), _amount(m, r2 >> 40), pos, 0)
                    )
                );
                targets[1] = address(book);
                calls[1] = abi.encodeCall(book.cancel, (OloOps.key(m.c), OloOps.tagW(m.c, OloOps.posW(pos, 0))));
                n = 2;
                break;
            }
        }
        assembly ("memory-safe") {
            mstore(targets, n)
            mstore(calls, n)
        }
        _try("flash", a, abi.encodeCall(book.flash, (address(t), amount, abi.encode(address(book), targets, calls))));
    }

    /// The owner moves a market's fee (`setMarketFee`): the market's next version, at the new fee, added to the markets
    /// the handler acts on. The version before stays in the list: its orders still fill, cancel and claim at its own
    /// fee, and every call that would rest an order in it again (a modify, a batch replace or modify) reverts. A move
    /// goes toward one of five fees, 1% of the quote (MarketLib.MAX_FEE_STEP_PPM) at most, the most one move steps.
    function setFee(uint256 r) external {
        Mkt memory m = _mkt(r);
        uint24[5] memory fees = [uint24(0), 50, 3_000, 500_000, 1_000_000];
        uint256 target = fees[(r >> 8) % 5];
        uint256 step = MarketLib.MAX_FEE_STEP_PPM;
        uint256 next = target > m.ppm + step ? m.ppm + step : target + step < m.ppm ? m.ppm - step : target;
        uint24 ppm = uint24(next);
        ++calls["fee"];
        (,, bool active) = book.makerShareOf(m.c);
        if (!active || ppm == m.ppm) return;
        book.setMarketFee(m.c.marketId(), ppm, 0);
        ++oks["fee"];
        m.c = book.configOf(m.c.marketId());
        m.ppm = ppm;
        _push(m);
    }

    // ---------------------------------------------------------------- takes

    /// What a take's checks need from before it: every listed order's tick, by position and by slot.
    struct Seen {
        uint256[NSCAN] posTick;
        uint256[NSLOT][3] slotWord;
        bytes list;
        uint256 worth; // the other side's open orders: their base, or their quote rounded down (quote mode)
    }

    /// The list a take of this side would build from the OLO Book now: every live order of the other side at its own
    /// tick (now and then a tick worse, which skips it), pool positions first or slots first.
    function _list(Mkt memory m, bool buy, bool inQuote, uint256 r) internal view returns (Seen memory s) {
        bytes memory entries;
        for (uint256 p; p < NSCAN; ++p) {
            uint256 word = book.orderWord(m.c, uint32(p));
            uint256 tick = word & 0x3ffffff;
            s.posTick[p] = tick;
            uint256 open = (word >> 33) & ((1 << 30) - 1);
            if (open == 0 || ((word >> 93) & 1 == 1) == buy) continue;
            uint256 seen = (r >> p) % 9 == 0 ? (buy ? tick - 1 : tick + 1) : tick;
            entries = bytes.concat(entries, OloOps.poolEntry(uint32(p), seen));
            uint256 amount = open * 10 ** ((word >> 26) & 0x7f);
            s.worth += inQuote ? PriceGrid.quoteDown(amount, tick) : amount;
        }
        bytes memory groups;
        for (uint256 i; i < 3; ++i) {
            for (uint256 k; k < NSLOT; ++k) {
                (uint256 word,) = book.batchOf(m.c, actors[i], uint16(k));
                s.slotWord[i][k] = word;
                // a slot with a sub-order in it; each sub-order on its side D_j, and only the other side's count
                // (the take skips the taker's own)
                if ((word >> 2) & ((1 << 244) - 1) == 0) continue;
                uint256[4] memory ticks;
                for (uint256 j; j < 4; ++j) {
                    uint256 sub = (word >> (2 + 61 * j)) & ((1 << 61) - 1);
                    uint256 tick = sub & 0x3ffffff;
                    uint256 open = sub >> 31;
                    ticks[j] = tick;
                    if (open == 0 || ((word >> (246 + j)) & 1 == 1) == buy) continue;
                    // now and then a tick worse, which skips the sub-order, as a pool entry's
                    if (uint256(keccak256(abi.encode(r, i, k, j))) % 9 == 0) ticks[j] = buy ? tick - 1 : tick + 1;
                    uint256 amount = open * 10 ** ((sub >> 26) & 0x1f);
                    s.worth += inQuote ? PriceGrid.quoteDown(amount, tick) : amount;
                }
                groups = bytes.concat(groups, OloOps.slotGroup(actors[i], uint16(k), 0xf, ticks));
            }
        }
        bytes memory pool = entries.length == 0 ? bytes("") : OloOps.poolList(entries);
        bytes memory slots = groups.length == 0 ? bytes("") : OloOps.batchList(groups);
        s.list = (r >> 100) & 1 == 0 ? bytes.concat(pool, slots) : bytes.concat(slots, pool);
    }

    struct TakeArgs {
        bool buy;
        bool inQuote;
        bool wallet;
        bool fok;
        uint256 amount;
        uint256 maxLeft;
        address who;
    }

    function take(uint256 r, uint256 r2) external {
        Mkt memory m = _mktDrain(r);
        TakeArgs memory a;
        a.buy = (r >> 8) & 1 == 1;
        a.inQuote = (r >> 9) & 1 == 1;
        a.wallet = (r >> 10) % 4 == 0;
        a.fok = (r >> 12) % 5 == 0;
        a.who = _actor(r >> 16);
        Seen memory s = _list(m, a.buy, a.inQuote, r2);
        // mostly 1% to 150% of what the other side holds, so takes fill and stop short; else any size
        a.amount = s.worth != 0 && (r >> 20) % 4 != 0
            ? 1 + s.worth * (1 + (r >> 24) % 150) / 100
            : (1 + (r >> 24) % 999) * 10 ** ((r >> 40) % 30);
        if (a.amount >= 1 << 112) a.amount = (1 << 112) - 1;
        // now and then the largest amount for a quote-mode sell at a fee near 100%, whose budget then passes 2^126
        if (a.inQuote && !a.buy && m.ppm >= 999_939 && (r >> 56) % 4 == 0) a.amount = (1 << 112) - 1;
        a.maxLeft = (r >> 48) % (a.amount + 1);
        if (a.maxLeft >= 1 << 77) a.maxLeft = (1 << 77) - 1;
        _takeRun(m, a, s);
    }

    /// A quote-mode take through the accounts of `amount` quote wei, by `who`, on the version `mkts[mi]` names, over
    /// the list `_list` builds, with every check a fuzzed take gets (test only).
    function takeQuoteExact(uint256 mi, bool buy, uint256 amount, address who, uint256 r2) external {
        Mkt memory m = mkts[mi];
        TakeArgs memory a;
        (a.buy, a.inQuote, a.amount, a.who) = (buy, true, amount, who);
        _takeRun(m, a, _list(m, buy, true, r2));
    }

    /// A base-mode take through the accounts of `amount`, by `who`, on the version `mkts[mi]` names, over the list
    /// `_list` builds (its worse ticks drawn from `r2`), with every check a fuzzed take gets: the regression tests'
    /// entry (test only; the fuzzer calls `take`).
    function takeExact(uint256 mi, bool buy, uint256 amount, address who, uint256 r2) external {
        Mkt memory m = mkts[mi];
        TakeArgs memory a;
        (a.buy, a.amount, a.who) = (buy, amount, who);
        _takeRun(m, a, _list(m, buy, false, r2));
    }

    function _takeRun(Mkt memory m, TakeArgs memory a, Seen memory s) internal {
        uint8 mode = (a.wallet ? OloOps.WALLET : 0) | (a.inQuote ? OloOps.QUOTE : 0) | (a.fok ? OloOps.FOK : 0);
        (uint256[2] memory acct0, uint256[2] memory wal0) = _holdings(m, a.who);
        vm.recordLogs();
        (bool ok, bytes memory ret) = _try(
            "take",
            a.who,
            abi.encodeCall(
                book.take, (OloOps.key(m.c), s.list, OloOps.tagW(m.c, OloOps.takeW(a.buy, a.amount, mode, a.maxLeft)))
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool fullFee = m.ppm == 1_000_000;
        if (!ok) {
            bytes4 sel = bytes4(ret);
            if (fullFee && !a.buy && sel == IOloBookBase.SellBelowFee.selector) ++fullFeeSellRefusals;
            uint256 rate = m.ppm < 1_000_000 ? 1_000_000 - m.ppm : 1;
            if (sel == IOloBookBase.AmountOverflow.selector && a.inQuote && !a.buy && a.amount * 1e6 / rate > 1 << 126)
            {
                ++budgetRefusals;
            }
            return;
        }
        (uint256 got, uint256 amt) = abi.decode(ret, (uint256, uint256));
        if (fullFee && !a.buy && got != 0) _flag("a sell filled at a fee of 100%");
        if (fullFee && !a.buy) ++fullFeeEmptySells;
        if (m.ppm >= 990_000 && got != 0) {
            if (a.buy) ++highFeeBuys;
            else ++highFeeSells;
        }
        if (got != 0 && !_current(m)) ++olderOks["take"];
        _checkTake(m, a, s, got, amt, logs);
        _checkMoves(m, a, got, amt, acct0, wal0);
    }

    /// The taker's two accounts and two wallet balances of the market's tokens (base, quote).
    function _holdings(Mkt memory m, address who)
        internal
        view
        returns (uint256[2] memory acct, uint256[2] memory wal)
    {
        acct[0] = book.balanceOf(book.tokenId(address(m.b)), who);
        acct[1] = book.balanceOf(book.tokenId(address(m.q)), who);
        wal[0] = m.b.balanceOf(who);
        wal[1] = m.q.balanceOf(who);
    }

    function _checkMoves(
        Mkt memory m,
        TakeArgs memory a,
        uint256 got,
        uint256 amt,
        uint256[2] memory acct0,
        uint256[2] memory wal0
    ) internal {
        (uint256[2] memory acct1, uint256[2] memory wal1) = _holdings(m, a.who);
        (uint256[2] memory before, uint256[2] memory now_) = a.wallet ? (wal0, wal1) : (acct0, acct1);
        // a buy: base in, quote out; a sell: base out, quote in
        bool baseOk = a.buy ? now_[0] - before[0] == got : before[0] - now_[0] == got;
        bool quoteOk = a.buy ? before[1] - now_[1] == amt : now_[1] - before[1] == amt;
        if (!baseOk || !quoteOk) _flag("the taker moved other than the take returned");
    }

    function _checkTake(Mkt memory m, TakeArgs memory a, Seen memory s, uint256 got, uint256 amt, Vm.Log[] memory logs)
        internal
    {
        // the caps
        if (!a.inQuote && got > a.amount) _flag("base mode filled past its amount");
        if (a.inQuote && amt > a.amount) _flag("quote mode past its amount");
        uint256 spent = a.inQuote ? amt : got;
        uint256 left = spent > a.amount ? 0 : a.amount - spent;
        if (a.fok && left > a.maxLeft) _flag("fill-or-kill left more than maxLeft");
        if (a.inQuote && got != 0) {
            ++quoteTakes;
            if (left != 0) ++stopsBelowAmount;
        }
        // the rounding, from the Take event
        bytes memory fills;
        uint256 quote;
        uint256 fee;
        uint256 baseAmt;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == IOloBookBase.Take.selector) {
                (, baseAmt, quote, fee, fills) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bytes));
                found = true;
            }
        }
        if (!found) {
            if (got != 0 || amt != 0) _flag("a fill without a Take");
            return;
        }
        (U512 memory num, uint256 sumBase, bool ownSide) = _exact(s, fills, a.buy);
        if (ownSide) _flag("a take filled a sub-order on the taker's own side");
        if (_batchRecords(fills) != 0) {
            ++batchFills[a.buy ? bytes32("buy") : bytes32("sell")];
            ++batchFills[a.inQuote ? bytes32("quote") : bytes32("base")];
            if (!_current(m)) ++batchFills["older"];
        }
        if (sumBase != got || baseAmt != got) _flag("the base is not the records' sum");
        uint256 q = (a.buy ? num.divUp(1e43) : num.divDown(1e43)).toUint();
        uint256 f = num.mul(m.ppm).divUp(1e49).toUint();
        if (quote != q) _flag("the quote is not the exact sum rounded once in the book's favour");
        if (fee != f) _flag("the fee is not the exact sum's, rounded up");
        if (!a.buy && f >= q) {
            _flag("a sell whose fee reached its quote succeeded");
            return;
        }
        if (amt != (a.buy ? q + f : q - f)) _flag("the quote amount is not quote and fee");
    }

    /// The fills' exact quote x 10^43 and their base, from the Take event's records and the ticks seen before the take.
    function _exact(Seen memory s, bytes memory f, bool buy)
        internal
        view
        returns (U512 memory num, uint256 sumBase, bool ownSide)
    {
        uint256 p;
        while (p < f.length) {
            uint256 kind = uint8(f[p]);
            uint256 end = p + 4 + ((uint256(uint8(f[p + 1])) << 16) | (uint256(uint8(f[p + 2])) << 8) | uint8(f[p + 3]));
            p += 4;
            while (p < end) {
                if (kind == 0) {
                    uint256 pos = _rd(f, p, 4);
                    uint256 amount = _rd(f, p + 5, 4) * 10 ** uint8(f[p + 4]);
                    num = num.add(_value(amount, s.posTick[pos]));
                    sumBase += amount;
                    p += 9;
                } else {
                    address maker = address(uint160(_rd(f, p, 20)));
                    uint256 slot = _rd(f, p + 20, 2);
                    uint256 n = uint8(f[p + 22]);
                    p += 23;
                    uint256 word = s.slotWord[_actorIndex(maker)][slot];
                    for (uint256 j; j < n; ++j) {
                        uint256 idx = uint8(f[p]);
                        if (((word >> (246 + idx)) & 1 == 1) == buy) ownSide = true;
                        uint256 amount = _rd(f, p + 2, 4) * 10 ** uint8(f[p + 1]);
                        num = num.add(_value(amount, (word >> (2 + 61 * idx)) & 0x3ffffff));
                        sumBase += amount;
                        p += 6;
                    }
                }
            }
        }
    }

    /// The batch records (sub-orders filled) in a Take event's fills.
    function _batchRecords(bytes memory f) internal pure returns (uint256 n) {
        uint256 p;
        while (p < f.length) {
            uint256 kind = uint8(f[p]);
            uint256 end = p + 4 + _rd(f, p + 1, 3); // the segment's header: kind 1 | length 3
            p += 4;
            if (kind == 0) {
                p = end;
                continue;
            }
            while (p < end) {
                uint256 k = uint8(f[p + 22]);
                n += k;
                p += 23 + 6 * k;
            }
        }
    }

    function _value(uint256 amount, uint256 tick) internal pure returns (U512 memory) {
        (uint256 d, uint256 mant) = PriceGrid.split(tick);
        return Wide.pow10(d).mul(mant).mul(amount);
    }

    function _actorIndex(address a) internal view returns (uint256) {
        for (uint256 i; i < 3; ++i) {
            if (actors[i] == a) return i;
        }
        revert("not an actor");
    }

    function _rd(bytes memory b, uint256 at_, uint256 n) internal pure returns (uint256 v) {
        for (uint256 i; i < n; ++i) {
            v = (v << 8) | uint8(b[at_ + i]);
        }
    }

    /// A takeThenRest: base mode, the rest at a tick in the band, in a random position with probes.
    function takeThenRest(uint256 r, uint256 r2) external {
        Mkt memory m = _mkt(r);
        bool buy = (r >> 8) & 1 == 1;
        Seen memory s = _list(m, buy, false, r2);
        uint256 amount = s.worth != 0 && (r >> 20) % 2 == 0 ? 1 + s.worth * (1 + (r >> 24) % 150) / 100 : _amount(m, r2);
        if (amount >= 1 << 112) amount = (1 << 112) - 1;
        uint8 mode = ((r >> 12) % 4 == 0 ? OloOps.WALLET : 0) | uint8(((r >> 14) % (MAX_PROBES + 1)) << 4);
        address who = _actor(r >> 16);
        (bool ok, bytes memory ret) = _try(
            "takeThenRest",
            who,
            abi.encodeCall(
                book.takeThenRest,
                (
                    OloOps.key(m.c),
                    s.list,
                    OloOps.tagW(m.c, OloOps.restW(buy, amount, _tick(m, r2 >> 64), mode, uint32((r >> 32) % NPOS)))
                )
            )
        );
        if (ok) {
            (uint256 got,, uint256 rested, uint256 restId) = abi.decode(ret, (uint256, uint256, uint256, uint256));
            if (got > amount) _flag("takeThenRest filled past its amount");
            if (rested != 0) _landed(uint32(restId));
            if (got != 0 && !_current(m)) ++olderOks["takeThenRest"];
        }
    }

    // ---------------------------------------------------------------- leaving

    /// Every actor cancels every order and slot it has, then withdraws both tokens of every market in full; the fee pots
    /// are collected. An OLO EVM contract that owes more than it holds reverts somewhere here.
    function everyoneLeaves() external {
        for (uint256 k; k < mkts.length; ++k) {
            Mkt memory m = mkts[k];
            for (uint256 p; p < NSCAN; ++p) {
                uint256 word = book.orderWord(m.c, uint32(p));
                if ((word >> 33) & ((1 << 60) - 1) == 0) continue; // no open units and no unclaimed fills
                vm.prank(address(uint160(word >> 96)));
                book.cancel(OloOps.key(m.c), OloOps.tagW(m.c, OloOps.posW(uint32(p), 0)));
            }
            for (uint256 i; i < 3; ++i) {
                for (uint256 slot; slot < NSLOT; ++slot) {
                    (uint256 word,) = book.batchOf(m.c, actors[i], uint16(slot));
                    // any sub-order, open or filled whole and unclaimed: a cancel settles them all
                    if (word >> 2 == 0) continue;
                    vm.prank(actors[i]);
                    (bool ok,) = address(book)
                        .call(
                            OloOps.batchCalldata(
                                book.manageBatchSubs.selector, m.c, OloOps.maskW(OloOps.CANCEL, uint16(slot), 0, 0xf)
                            )
                        );
                    require(ok, "a slot's cancel");
                }
            }
        }
        for (uint256 i; i < 3; ++i) {
            for (uint256 t; t < tokens.length; ++t) {
                uint256 held = book.balanceOf(book.tokenId(address(tokens[t])), actors[i]);
                if (held != 0) {
                    vm.prank(actors[i]);
                    book.withdraw(address(tokens[t]), held);
                }
            }
        }
        for (uint256 t; t < tokens.length; ++t) {
            book.collectFees(address(tokens[t]));
        }
    }
}

/// The actors' code, etched at their addresses so they can take a flash: the callback runs the program its data
/// carries (the OLO EVM contract's address, then each call's target and data), each call's revert bubbling.
contract FlashActor {
    function oloFlashCallback(address, uint256, bytes calldata data) external {
        (address book, address[] memory targets, bytes[] memory calls) = abi.decode(data, (address, address[], bytes[]));
        require(msg.sender == book, "FlashActor: caller");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = targets[i].call(calls[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

/// Handler-based invariants over the whole OLO EVM contract: pool orders, batch slots, takes in base and quote mode
/// through accounts and wallets, takeThenRest, claims, cancels, modifies, multicalls, deposits, withdrawals,
/// maker-share changes and fee moves (each a market's next version, which joins the markets acted on; the versions
/// before keep their orders), fee collection, by three actors on seven markets whose tokens have 0, 6, 8, 18 and 24
/// decimals and whose makers quote around a decade boundary each (decades 16/17, 28/29, 30/31, 39/40, 40/41, 55/56 and
/// 59/60: quotes that are fractions of a wei and quotes of whole wei, fees from 0 to 100%, two of them listed at
/// 999,940 and 1,000,000 ppm, spacings of 1 to 100, minQuote zero and not). After every call:
///   - solvency: the contract holds, of every token, at least every account, every fee pot and every live order's
///   payout
///     as the contract would make it (open escrow refunded, fills' proceeds and fee, each rounded as the contract
///     rounds);
///   - no value created: every token's supply is in the actors' and the fee recipient's wallets and the contract, and
///   what
///     the actors and the pots are owed (accounts, payouts) is no more than the contract holds;
///   - the handler's checks (OloHandler): amounts within their caps, fill-or-kill within maxLeft, every take's quote and
///     fee its exact sum rounded once in the contract's favour, the taker moved by exactly what the take returned.
/// After each run everyone leaves (cancels, claims, withdraws, the pots collected) without a revert, and the contract
/// is left with no less than nothing of any token.
contract OloInvariantTest is OloBase {
    OloHandler handler;
    MockERC20[] toks;
    address[3] actors;

    function setUp() public {
        _deploy();
        MockERC20 d0 = new MockERC20("Zero", "D0", 0);
        MockERC20 d6 = new MockERC20("Six", "D6", 6);
        MockERC20 d8 = new MockERC20("Eight", "D8", 8);
        MockERC20 d18 = new MockERC20("Eighteen", "D18", 18);
        MockERC20 d24 = new MockERC20("TwentyFour", "D24", 24);
        toks.push(d0);
        toks.push(d6);
        toks.push(d8);
        toks.push(d18);
        toks.push(d24);
        actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
        // code at the actors' addresses, for a flash's callback (FlashActor); nothing else they do reads it
        for (uint256 i; i < 3; ++i) {
            vm.etch(actors[i], type(FlashActor).runtimeCode);
        }
        handler = new OloHandler(book, actors, toks);
        // D8/D6 at $100,000 (P = 1,000, decade 41), 200 ppm, 6 figures, minQuote 1 D6
        _list(d8, d6, 200, 6, 1e6, 41, 40, 2, 10);
        // D18/D6 at $1,000 (P = 1e-9, decade 29), 0.3%, 5 figures, no minQuote
        _list(d18, d6, 3_000, 5, 0, 29, 600, 8, 21);
        // D0/D18 at 1 D18 a unit (P = 1e18, decade 56), no fee, 6 figures
        _list(d0, d18, 0, 6, 0, 56, 30, 0, 4);
        // D24/D0 at 1e-21 (decade 17), 50%, 6 figures
        _list(d24, d0, 500_000, 6, 0, 17, 30, 14, 27);
        // D6/D24 at 1e22 (decade 60), 50 ppm, 4 figures, minQuote 1e20
        _list(d6, d24, 50, 4, 1e20, 60, 3_000, 0, 9);
        // D6/D8 at 1 D8 a D6 (P = 100, decade 40), a fee of 100%: every sell that fills refused, buys pay twice
        _list(d6, d8, 1_000_000, 6, 0, 40, 40, 2, 10);
        // D18/D8 at $1,000 (P = 1e-7, decade 31), 999,940 ppm: a quote-mode sell's budget up to about 16,667 times
        // its amount
        _list(d18, d8, 999_940, 5, 0, 31, 600, 8, 21);
        for (uint256 i; i < 3; ++i) {
            for (uint256 t; t < toks.length; ++t) {
                toks[t].mint(actors[i], 1e40);
                vm.startPrank(actors[i]);
                toks[t].approve(address(book), type(uint256).max);
                book.deposit(address(toks[t]), 1e37);
                vm.stopPrank();
            }
        }
        book.transferOwnership(address(handler));
        handler.acceptOwnership();
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](15);
        sel[0] = OloHandler.place.selector;
        sel[1] = OloHandler.cancel.selector;
        sel[2] = OloHandler.claim.selector;
        sel[3] = OloHandler.modify.selector;
        sel[4] = OloHandler.batch.selector;
        sel[5] = OloHandler.multicall.selector;
        sel[6] = OloHandler.deposit.selector;
        sel[7] = OloHandler.withdraw.selector;
        sel[8] = OloHandler.setShare.selector;
        sel[9] = OloHandler.collectFees.selector;
        sel[10] = OloHandler.take.selector;
        sel[11] = OloHandler.take.selector; // takes twice as often
        sel[12] = OloHandler.takeThenRest.selector;
        sel[13] = OloHandler.setFee.selector;
        sel[14] = OloHandler.flash.selector;
        targetSelector(FuzzSelector(address(handler), sel));
    }

    function _list(
        MockERC20 b,
        MockERC20 q,
        uint24 ppm,
        uint8 sigFigs,
        uint96 minQuote,
        uint256 decade,
        uint256 spread,
        uint256 lo,
        uint256 hi
    ) internal {
        MarketWord mc = book.configOf(book.listMarketQuote(address(b), address(q), ppm, sigFigs, minQuote, 0));
        handler.addMarket(
            Mkt(mc, b, q, decade * PriceGrid.PER_DECADE, spread, PriceGrid.spacingOf(sigFigs), lo, hi, ppm)
        );
    }

    /// What the contract owes of token `t`: every account (the actors'), the fee pot, and every live order's payout.
    function _owed(MockERC20 t) internal view returns (uint256 owed) {
        uint256 id = book.tokenId(address(t));
        for (uint256 i; i < 3; ++i) {
            owed += book.balanceOf(id, actors[i]);
        }
        owed += book.balanceOf(id, address(0));
        for (uint256 k; k < handler.marketCount(); ++k) {
            Mkt memory m = handler.market(k);
            bool isBase = address(m.b) == address(t);
            bool isQuote = address(m.q) == address(t);
            if (!isBase && !isQuote) continue;
            for (uint256 p; p < handler.NSCAN(); ++p) {
                uint256 word = book.orderWord(m.c, uint32(p));
                uint256 unit = 10 ** ((word >> 26) & 0x7f);
                owed += _payout(
                    m,
                    isBase,
                    word & 0x3ffffff,
                    (word >> 93) & 1 == 1,
                    ((word >> 33) & ((1 << 30) - 1)) * unit,
                    ((word >> 63) & ((1 << 30) - 1)) * unit
                );
            }
            for (uint256 i; i < 3; ++i) {
                for (uint256 s; s < 2; ++s) {
                    (uint256 word, uint256 set) = book.batchOf(m.c, actors[i], uint16(s));
                    for (uint256 j; j < 4; ++j) {
                        uint256 sub = (word >> (2 + 61 * j)) & ((1 << 61) - 1);
                        if (sub == 0) continue; // empty: owes nothing (its base is left over)
                        uint256 unit = 10 ** ((sub >> 26) & 0x1f);
                        uint256 open = sub >> 31;
                        uint256 baseUnits = (set >> (30 * j)) & ((1 << 30) - 1);
                        owed += _payout(
                            m,
                            isBase,
                            sub & 0x3ffffff,
                            (word >> (246 + j)) & 1 == 1,
                            open * unit,
                            (baseUnits - open) * unit
                        );
                    }
                }
            }
        }
    }

    /// One order's payout in the token asked for, as the contract pays it at a settle: an ask refunds its open base and
    /// is paid its fills' quote rounded down; a bid refunds its open quote rounded down and is paid its fills' base; the
    /// fills' fee, floored, goes to the maker and the pot.
    function _payout(Mkt memory m, bool isBase, uint256 tick, bool isBid, uint256 open, uint256 filled)
        internal
        pure
        returns (uint256)
    {
        if (open == 0 && filled == 0) return 0;
        if (isBase) return isBid ? filled : open;
        uint256 fee = PriceGrid.feeDown(filled, tick, m.ppm);
        return (isBid ? PriceGrid.quoteDown(open, tick) : PriceGrid.quoteDown(filled, tick)) + fee;
    }

    function invariant_solvent() public view {
        for (uint256 t; t < toks.length; ++t) {
            assertGe(toks[t].balanceOf(address(book)), _owed(toks[t]), string.concat("solvent: ", toks[t].symbol()));
        }
    }

    function invariant_no_value_created() public view {
        for (uint256 t; t < toks.length; ++t) {
            MockERC20 tk = toks[t];
            uint256 held = tk.balanceOf(address(book)) + tk.balanceOf(address(this));
            for (uint256 i; i < 3; ++i) {
                held += tk.balanceOf(actors[i]);
            }
            assertEq(held, tk.totalSupply(), "every token is in a wallet or the book");
        }
    }

    function invariant_handler_checks() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    function afterInvariant() public {
        handler.everyoneLeaves();
        for (uint256 t; t < toks.length; ++t) {
            assertEq(_owed(toks[t]), 0, "nothing owed once everyone left");
        }
    }

    /// The suite reaches what it means to: takes of both modes that fill and that stop short, every kind of call
    /// succeeding, share changes and fee moves included, the calls that act in an older version (cancel, claim, a
    /// batch cancel or claim, a multicall under its C, take and takeThenRest fills) succeeding there, and multicalls
    /// under a header K (a short run of the handler by hand, so the counts are this test's own).
    function test_handler_reaches_everything() public {
        for (uint256 s; s < 1000; ++s) {
            uint256 r = uint256(keccak256(abi.encode("inv", s)));
            uint256 r2 = uint256(keccak256(abi.encode("inv2", s)));
            uint256 k = r % 13;
            if (k == 0) handler.place(r >> 8, r2);
            else if (k == 1) handler.cancel(r >> 8);
            else if (k == 2) handler.claim(r >> 8);
            else if (k == 3) handler.modify(r >> 8, r2);
            else if (k == 4) handler.batch(r >> 8, r2);
            else if (k == 5) handler.multicall(r >> 8, r2);
            else if (k == 6) handler.deposit(r >> 8, r2);
            else if (k == 7) handler.withdraw(r >> 8, r2);
            // a share change makes a market's next version and leaves its orders in the version before, so one draw in
            // three changes it and the others cancel: the current versions keep orders to cancel, claim and modify
            else if (k == 8 && (r >> 100) % 3 == 0) handler.setShare(r >> 8);
            else if (k == 8) handler.cancel(r >> 8);
            else if (k == 9) handler.collectFees(r >> 8);
            else if (k == 12) handler.takeThenRest(r >> 8, r2);
            else handler.take(r >> 8, r2);
            if (k == 0 || k == 4) handler.place(r2, r); // more makers than takers early on
            if (s % 25 == 12) handler.setFee(r2); // a fee move now and then: older versions keep their orders
            if (s % 8 == 5) handler.flash(r2 >> 8, r); // a flash every eighth step, the draws above as they were
        }
        invariant_solvent();
        invariant_no_value_created();
        invariant_handler_checks();
        string[13] memory names = [
            "place",
            "cancel",
            "claim",
            "modify",
            "batch",
            "multicall",
            "deposit",
            "withdraw",
            "take",
            "takeThenRest",
            "fee",
            "share",
            "flash"
        ];
        for (uint256 i; i < names.length; ++i) {
            emit log_named_uint(names[i], handler.oks(bytes32(bytes(names[i]))));
            assertGt(handler.oks(bytes32(bytes(names[i]))), 2, names[i]);
        }
        // and in older versions than their market's current one: fills, settles, batch settles, multicall settles
        // under a header C; and multicalls under a header K
        string[6] memory older = ["cancel", "claim", "batch", "multicall", "take", "takeThenRest"];
        for (uint256 i; i < older.length; ++i) {
            emit log_named_uint(string.concat("older: ", older[i]), handler.olderOks(bytes32(bytes(older[i]))));
        }
        for (uint256 i; i < older.length; ++i) {
            assertGt(handler.olderOks(bytes32(bytes(older[i]))), 0, string.concat("older: ", older[i]));
        }
        string[5] memory bf = ["buy", "sell", "base", "quote", "older"];
        for (uint256 i; i < bf.length; ++i) {
            emit log_named_uint(string.concat("batch fills: ", bf[i]), handler.batchFills(bytes32(bytes(bf[i]))));
        }
        emit log_named_uint("batch settles of fills", handler.batchSettles("all"));
        emit log_named_uint("batch settles of fills, older", handler.batchSettles("older"));
        for (uint256 i; i < bf.length; ++i) {
            assertGt(handler.batchFills(bytes32(bytes(bf[i]))), 0, string.concat("batch fills: ", bf[i]));
        }
        assertGt(handler.mixedSeen(), 0, "batch operations on a slot holding both sides");
        assertEq(handler.sideFaults(), 0, "every batch word's side bits as the contract keeps them");
        assertGt(handler.batchSettles("all"), 0, "batch settles of fills");
        assertGt(handler.batchSettles("older"), 0, "batch settles of fills, older");
        emit log_named_uint("multicalls under K", handler.keyHeaderOks());
        assertGt(handler.keyHeaderOks(), 2, "multicalls under K");
        emit log_named_uint("quote-mode takes that filled", handler.quoteTakes());
        emit log_named_uint("of them, leaving part of the amount", handler.stopsBelowAmount());
        assertGt(handler.quoteTakes(), 5);
        emit log_named_uint("sells refused at a fee of 100%", handler.fullFeeSellRefusals());
        emit log_named_uint("sells at a fee of 100% that filled nothing", handler.fullFeeEmptySells());
        emit log_named_uint("buys that filled at a fee of 990,000 ppm or more", handler.highFeeBuys());
        emit log_named_uint("sells that filled at a fee of 990,000 ppm or more", handler.highFeeSells());
        emit log_named_uint("budgets past 2^126 refused", handler.budgetRefusals());
        assertGt(handler.fullFeeSellRefusals(), 0, "sells refused at a fee of 100%");
        assertGt(handler.highFeeBuys(), 0, "buys that filled at a fee of 990,000 ppm or more");
        assertGt(handler.highFeeSells(), 0, "sells that filled at a fee of 990,000 ppm or more");
        assertGt(handler.budgetRefusals(), 0, "quote-mode sells whose budget passed 2^126");
        emit log_named_uint("orders landed past the start range", handler.probedPast());
        assertGt(handler.probedPast(), 0, "orders landed past the start range");
        afterInvariant();
    }

    /// The handler counts a quote-mode sell whose budget passes 2^126, refused AmountOverflow: a bid in market 5 (D6/D8
    /// at 100%) and a sell of 1e32 quote wei, a budget of 1e38; the take's checks find nothing wrong.
    function test_the_handler_counts_a_refused_budget() public {
        Mkt memory m = handler.market(5);
        assertEq(m.ppm, 1_000_000);
        vm.prank(actors[0]);
        book.place(OloOps.key(m.c), OloOps.placeW(true, m.center, 1e6, 3, 0));
        // r2 = 2^10: (r2 >> 3) % 9 = 2, so the list names position 3 at its own tick
        handler.takeQuoteExact(5, false, 1e32, actors[1], 1 << 10);
        assertEq(handler.budgetRefusals(), 1);
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    // The batch settle counter counts an operation only when it paid fills: two operations that
    // succeed on a slot with fills to pay but pay none, and the two that do. Market 1 (D18/D6, 3,000 ppm, 5 figures,
    // no minQuote), an ask slot of actor 0 at P = 1e-9, actor 1 the taker.

    uint256 constant T1 = 26_100_000; // market 1's center: decade 29, mantissa 100,000

    /// Actor 0 posts `orders` in its slot `slot` of market 1's current version; actor 1 buys half of sub-order 0.
    function _postAndFill(uint16 slot, uint256[4] memory orders) internal returns (MarketWord c) {
        c = book.configOf(handler.market(1).c.marketId());
        uint256 oks0 = handler.oks("batch");
        handler.batchExact(1, OloOps.POST, false, slot, 0, 0, orders, actors[0]);
        assertEq(handler.oks("batch"), oks0 + 1, "the post");
        vm.prank(actors[1]);
        (uint256 got,) = book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(actors[0], slot, 0x1, T1)),
            OloOps.tagW(c, OloOps.takeW(true, 5e17, 0))
        );
        assertEq(got, 5e17, "half of sub-order 0 filled");
    }

    /// A cancel of sub-order 2 alone (no fills) leaves sub-order 0's fills unpaid: not counted; a cancel of sub-order
    /// 0 pays them: counted.
    function test_batch_settles_skip_a_cancel_that_leaves_the_fills() public {
        _postAndFill(0, [OloOps.sub(T1, 1e18), 0, OloOps.sub(T1 + 10, 1e18), 0]);
        uint256[4] memory none;
        uint256 all0 = handler.batchSettles("all");
        uint256 oks0 = handler.oks("batch");
        handler.batchExact(1, OloOps.CANCEL, false, 0, 0, 0x4, none, actors[0]);
        assertEq(handler.oks("batch"), oks0 + 1, "the cancel of sub-order 2 ran");
        assertEq(handler.batchSettles("all"), all0, "it paid no fills");
        handler.batchExact(1, OloOps.CANCEL, false, 0, 0, 0x1, none, actors[0]);
        assertEq(handler.oks("batch"), oks0 + 2, "the cancel of sub-order 0 ran");
        assertEq(handler.batchSettles("all"), all0 + 1, "it paid sub-order 0's fills");
    }

    /// After a fee move, a post naming the older version rests in the current one and leaves the older slot's fills
    /// unpaid: not counted; a cancel of the older slot pays them: counted, as older.
    function test_batch_settles_skip_a_post_in_another_version() public {
        MarketWord v1 = _postAndFill(1, [OloOps.sub(T1, 1e18), 0, 0, 0]);
        // r = 1: mkts[1 % 7] is market 1, and (1 >> 8) % 5 = 0 aims its fee at 0, one step from 3,000
        handler.setFee(1);
        assertEq(handler.marketCount(), 8, "market 1's next version");
        assertTrue(MarketWord.unwrap(book.configOf(v1.marketId())) != MarketWord.unwrap(v1));
        (uint256 word0, uint256 set0) = book.batchOf(v1, actors[0], 1);
        uint256[4] memory none;
        uint256 all0 = handler.batchSettles("all");
        uint256 older0 = handler.batchSettles("older");
        uint256 oks0 = handler.oks("batch");
        // the post names version 1 (mkts[1]) and rests in version 2
        handler.batchExact(1, OloOps.POST, false, 1, 0, 0, [OloOps.sub(T1, 1e18), 0, 0, 0], actors[0]);
        assertEq(handler.oks("batch"), oks0 + 1, "the post ran");
        (uint256 word1, uint256 set1) = book.batchOf(v1, actors[0], 1);
        assertEq(word1, word0, "version 1's slot untouched");
        assertEq(set1, set0, "version 1's settlement word untouched");
        assertEq(handler.batchSettles("all"), all0, "the post paid no fills");
        assertEq(handler.batchSettles("older"), older0, "nor in the older version");
        handler.batchExact(1, OloOps.CANCEL, false, 1, 0, 0xf, none, actors[0]);
        assertEq(handler.oks("batch"), oks0 + 2, "the older slot's cancel ran");
        assertEq(handler.batchSettles("all"), all0 + 1, "it paid the fills");
        assertEq(handler.batchSettles("older"), older0 + 1, "in the older version");
    }

    // Position 10, the last a probe reaches (a takeThenRest's rest from position 7 with 3 probes): every scan reads it.
    // Market 1; actor 0 rests bids at 7, 8 and 9 and an ask that probes from 7 to 10, placed by the
    // contract directly so the landing is forced; actor 1 takes.

    /// Actor 0's bids at 7, 8, 9 (each probing from 7) and then its ask of 1e18 at T1, from 7 with 3 probes: it lands
    /// in 10, the last position NSCAN covers.
    function _restAt10() internal returns (MarketWord c) {
        c = handler.market(1).c;
        assertEq(handler.NSCAN(), 11, "positions 0 .. 10 scanned");
        vm.startPrank(actors[0]);
        for (uint8 k; k < 3; ++k) {
            (uint256 bidId,) = book.place(OloOps.key(c), OloOps.placeW(true, T1 - 10, 1e18, 7, uint8(uint256(k) << 4)));
            assertEq(uint32(bidId), 7 + k, "a bid in 7, 8, 9");
        }
        (uint256 id,) = book.place(OloOps.key(c), OloOps.placeW(false, T1, 1e18, 7, 3 << 4));
        vm.stopPrank();
        assertEq(uint32(id), 10, "the ask probed from 7 to 10");
    }

    /// The ask in 10 is owed: moving 1e18 base from actor 0's account into the order leaves what the contract owes of
    /// the base unchanged (a scan that missed 10 would owe 1e18 less); and everyone leaving cancels it, nothing owed.
    function test_an_order_in_position_10_is_owed_and_leaves() public {
        MockERC20 base = handler.market(1).b;
        uint256 owedBefore = _owed(base);
        MarketWord c = _restAt10();
        assertEq(_owed(base), owedBefore, "the ask in 10 owed, as the account it left was");
        (, uint256 open,,,) = book.orderOf(c, 10);
        assertEq(open, 1e18);
        afterInvariant(); // everyone leaves; nothing owed of any token
        assertFalse(PoolWord.wrap(book.orderWord(c, 10)).isLive(), "the order in 10 cancelled");
    }

    /// The handler's take list reaches 10 and fills part of the ask there (the bids in 7-9 are the taker's own side);
    /// the handler's claim and cancel, scanning from 10, pay its fills and cancel it.
    function test_the_handler_fills_claims_and_cancels_position_10() public {
        MarketWord c = _restAt10();
        // r2 = 2^10: (r2 >> 10) % 9 = 1, so the list names 10 at its own tick (a draw of 0 would name a worse one)
        handler.takeExact(1, true, 4e17, actors[1], 1 << 10);
        assertEq(handler.violations(), 0, handler.lastViolation());
        (, uint256 open, uint256 filled,,) = book.orderOf(c, 10);
        assertEq(filled, 4e17, "the take filled 4e17 of the ask in 10");
        assertEq(open, 6e17);
        // r = 2 + 10 << 16: market 1 (r % 7), the scan from position 10 ((r >> 16) % 11), its owner ((r >> 8) % 2 = 0),
        // through the accounts; 10 is the one position with fills
        uint256 r = 2 + (10 << 16);
        uint256 claims0 = handler.oks("claim");
        handler.claim(r);
        assertEq(handler.oks("claim"), claims0 + 1, "the claim ran");
        (, open, filled,,) = book.orderOf(c, 10);
        assertEq(filled, 0, "the claim paid 10's fills");
        assertEq(open, 6e17);
        uint256 cancels0 = handler.oks("cancel");
        handler.cancel(r);
        assertEq(handler.oks("cancel"), cancels0 + 1, "the cancel ran");
        assertFalse(PoolWord.wrap(book.orderWord(c, 10)).isLive(), "the cancel emptied 10");
    }
}
