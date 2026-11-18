// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {BatchView} from "./BatchView.sol";
import {SlotRef} from "./SlotRef.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {ReentrantToken} from "./utils/HostileTokens.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {BatchLib, OloSlots} from "../src/OloTypes.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";

using MarketLib for MarketWord;

/// The batch slots held to their plainest reference (SlotRef.sol), as Seaport holds its optimized contracts to its
/// reference ones; this replaces the lot model's exact model of the slots (legacy OloBatchModel.t.sol). Random
/// operations, valid and not (unknown kinds, settle flags that mean nothing, empty masks, ticks off the grid or the
/// spacing, sizes of no unit or worth less than minQuote, NoChange, busy and empty slots, a C no market was listed
/// with), a third of them with every order on one side and the rest with random sides (a slot holding bids and asks;
/// a modify's read for every index it names, turning a live sub-order whose side differs, half of them each live
/// sub-order's own; a cancel's and a claim's not at all), by
/// two makers (one rich, one whose accounts run short) on two slots each, on three markets: the fixture (6 figures, 50
/// ppm, minQuote 1, around T where a tick below is decade 37), one of 4 figures at 3000 ppm with a minQuote of 1e6, and
/// an 18-decimal base against the 6-decimal quote near $2,500 (decade 29, where every quote is a fraction the OLO EVM
/// contract rounds; 5 figures, 300 ppm, minQuote 1e4). After every operation: the same error, the same two words, the
/// settlement word written exactly when it changed, the BatchUpdated event, and the maker's accounts, wallet and the
/// fee pot moved by the reference's sums at the market's share now, split between account and wallet by the settle
/// flags. Random takes over the slots, base mode and quote mode, their groups naming random sub-orders at their tick, a
/// tick either side, a stale tick, a bound past every price or 0, a slot nobody wrote, the same slot twice, over one or
/// two segments. After every take: the same main words, the settlement words untouched, the same fill records, quote,
/// fee (the exact sum rounded once, computed here) and base, the taker's accounts, and in quote mode each sub-order
/// filled the largest number of units the budget's rule holds (a buy: its quote and fee, each rounded up, at most A; a
/// sell: Q x (1 - f) at most A), the taker's amount within A, and its leftover under one more unit's worth where the
/// budget stopped a sub-order short. Every run ends with each slot cancelled and everyone leaving: the contract owes
/// nothing it does not hold, keeps no base wei and at most a wei of quote per rounding.
contract OloSlotRefTest is OloBase {
    /// ETH at $2,500, an 18-decimal base against the 6-decimal quote: P = 2.5e-9 quote wei per base wei (decade 29).
    uint256 constant E = 26_250_000;
    uint256 constant STEPS = 80;
    uint256 constant UNITS = (1 << 30) - 1;
    uint256 constant MAX_AMOUNT = (1 << 112) - 1;
    /// A slot nobody wrote, which takes name too (key 4).
    address constant NOBODY = address(0x7777);
    uint16 constant NOBODY_SLOT = 77;

    MockERC20 weth;
    MarketWord[3] cs; // each market's current C
    MarketWord[][3] vs; // each market's versions, the listing's first and the current one last
    // the test's own record of each version's maker share and fee, made when the test makes the version and held to
    // `configOf` there: the reference settles and takes at these, not at the bits of the C it reads back
    uint256[][3] vShares;
    uint256[][3] vFees;
    mapping(uint256 c => uint256) vIndex; // a version's C -> its index in its market's record, plus one
    uint32[3] ids;
    MockERC20[3] bases;
    uint256[3] centers;
    uint256[3] shares;
    bool finishing; // `_finish` runs: its cancels are not counted as the fuzz's settles
    address[2] mk;
    uint16[2] slotIds = [uint16(3), 9];

    // What the fuzz reached, for the coverage test.
    uint256[5] okKind; // operations that went through, by kind
    mapping(bytes4 => uint256) errs; // operations refused, by error
    uint256 setKept; // operations that left the settlement word as it was, unwritten
    uint256 walletOps; // operations with settle flags that moved the wallet
    uint256 autoPulls; // AUTO debits the account could not cover: the rest pulled from the wallet
    uint256 baseTakes; // base-mode takes that filled
    uint256 quoteTakes; // quote-mode takes that filled
    uint256 budgetCuts; // quote-mode takes whose budget stopped a sub-order short (the leftover's bound checked)
    uint256 qFills; // fills of sub-orders at q > 0
    uint256 sellBelowFee; // sells refused for a fee above their quote
    uint256 roundings; // a bound on the wei the contract keeps by rounding: 2 a take, 16 an operation (4 a sub-order)
    uint256 oldSettles; // cancels and claims that paid fills on an older version's slot (before `_finish`)
    uint256 oldFills; // takes that filled an older version's sub-orders
    uint256 shareMoves; // share changes made (each a new version)
    uint256 feeMoves; // fee changes made (each a new version)
    uint256 mixedOps; // operations that went through leaving a slot holding both sides
    uint256 mixedFills; // take groups that filled a slot holding both sides
    uint256 ownSkips; // named sub-orders with units open that a take skipped for resting on the taker's own side
    uint256 liveFlips; // live sub-orders a modify turned to the other side

    function setUp() public {
        _deploy();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ids[0] = m;
        ids[1] = book.listMarketQuote(address(base), address(quote), 3000, 4, 1e6, 0);
        ids[2] = book.listMarketQuote(address(weth), address(quote), 300, 5, 1e4, 0);
        bases = [base, base, weth];
        centers = [T, T, E];
        shares = [uint256(7_000), 10_000, 2_500];
        uint256[3] memory fees = [uint256(50), 3000, 300];
        for (uint256 k; k < 3; ++k) {
            // listed at the fixture's global share, 10,000
            _record(k, 10_000, fees[k]);
            if (shares[k] != 10_000) {
                book.setMarketMakerShare(ids[k], uint16(shares[k]));
                _record(k, shares[k], fees[k]);
            }
        }
        c = cs[0]; // the fixture market's current version, which the unit tests below use
        _fund(taker, 1e37);
        mk[0] = address(0x5100);
        mk[1] = address(0x5200);
        _fund(mk[0], 1e36);
        _fund(mk[1], 1e19); // runs short: InsufficientBalance without flags, AUTO pulls the rest from the wallet
        makers.push(mk[0]);
        makers.push(mk[1]);
    }

    /// `a` gets `deposit` and 1e37 more of each token (base, quote, weth), approves the contract, and deposits
    /// `deposit` of each: the wallet always covers what an operation pulls.
    /// Market k's next version in the test's record, at `share` and `fee`: the contract's current C must carry exactly
    /// these (and be one version on), and becomes cs[k].
    function _record(uint256 k, uint256 share, uint256 fee) internal {
        MarketWord now_ = book.configOf(ids[k]);
        assertEq(now_.makerBps(), share, "the version's share, as the test set it");
        assertEq(now_.feePpm(), fee, "the version's fee, as the test set it");
        assertEq(now_.version(), vs[k].length + 1, "one version a change");
        vIndex[MarketWord.unwrap(now_)] = vs[k].length + 1;
        vs[k].push(now_);
        vShares[k].push(share);
        vFees[k].push(fee);
        cs[k] = now_;
    }

    /// The index of version `cc` in market k's record.
    function _vi(uint256 k, MarketWord cc) internal view returns (uint256) {
        uint256 i = vIndex[MarketWord.unwrap(cc)];
        require(i != 0 && cc.marketId() == ids[k], "not a version of the market");
        return i - 1;
    }

    /// Version `cc`'s C as the reference reads it: its key and version, with the share and the fee the test recorded.
    function _modelC(uint256 k, MarketWord cc) internal view returns (MarketWord) {
        uint256 i = _vi(k, cc);
        uint256 w = MarketWord.unwrap(cc) & ~((uint256(0x3fff) << 174) | (uint256(0xfffff) << 188));
        return MarketWord.wrap(w | (vShares[k][i] << 174) | (vFees[k][i] << 188));
    }

    function _fund(address a, uint256 deposit) internal {
        MockERC20[3] memory ts = [base, quote, weth];
        for (uint256 i; i < 3; ++i) {
            ts[i].mint(a, deposit + 1e37);
            vm.startPrank(a);
            ts[i].approve(address(book), type(uint256).max);
            book.deposit(address(ts[i]), deposit);
            vm.stopPrank();
        }
    }

    function _rnd(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    /// Slot key 0-3: maker key / 2's slot key % 2; key 4: the slot nobody wrote.
    function _who(uint256 key) internal view returns (address, uint16) {
        if (key == 4) return (NOBODY, NOBODY_SLOT);
        return (mk[key >> 1], slotIds[key & 1]);
    }

    function _has(bytes32[] memory slots, uint256 slot) internal pure returns (bool) {
        for (uint256 i; i < slots.length; ++i) {
            if (uint256(slots[i]) == slot) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ operations

    /// A maker's two tokens of a market: its accounts and wallet, and the quote's fee pot.
    struct Bals {
        uint256 acctB;
        uint256 acctQ;
        uint256 walB;
        uint256 walQ;
        uint256 pot;
    }

    function _bals(address a, uint256 k) internal view returns (Bals memory x) {
        x.acctB = _bal(a, bases[k]);
        x.acctQ = _bal(a, quote);
        x.walB = bases[k].balanceOf(a);
        x.walQ = quote.balanceOf(a);
        x.pot = _pot(quote);
    }

    /// What an operation moves: per token the account's and the wallet's change (signed), and the pot's gain.
    struct Moves {
        int256 acctB;
        int256 acctQ;
        int256 walB;
        int256 walQ;
        uint256 pot;
    }

    /// How a flow of `flow` (signed: + paid to the maker) on an account holding `held` settles under `flags`
    /// (OloBookAssets._commit; with no flags the account moves now): the account's and the wallet's change. A credit
    /// goes to the wallet with WALLET, else to the account; a debit with AUTO comes from the account first and the
    /// rest from the wallet, with WALLET alone from the wallet, else from the account.
    function _split(uint8 flags, uint256 held, int256 flow) internal returns (int256 acct, int256 wallet) {
        if (flow >= 0) return flags & 0x02 != 0 ? (int256(0), flow) : (flow, int256(0));
        uint256 need = uint256(-flow);
        if (flags & 0x04 != 0) {
            uint256 fromAcct = held < need ? held : need;
            if (fromAcct < need) ++autoPulls;
            return (-int256(fromAcct), -int256(need - fromAcct));
        }
        if (flags & 0x02 != 0) return (int256(0), flow);
        return (flow, int256(0));
    }

    /// The moves of the reference's sums `s` at the maker share `share`: the fee's maker part (floored) joins the
    /// quote, the rest goes to the pot. Without flags each flow moves the account now, quote first: a debit past the
    /// balance is InsufficientBalance (returned; 0 otherwise).
    function _moves(Moves memory mv, Bals memory b, SlotRef.Sums memory s, uint8 flags, uint256 share)
        internal
        returns (bytes4)
    {
        uint256 makerPart = s.fee * share / 10_000;
        mv.pot = s.fee - makerPart;
        int256 quoteFlow = int256(s.quoteIn + makerPart) - int256(s.quoteOut);
        int256 baseFlow = int256(s.baseIn) - int256(s.baseOut);
        if (flags == 0) {
            bool shortQ = quoteFlow < 0 && b.acctQ < uint256(-quoteFlow);
            bool shortB = baseFlow < 0 && b.acctB < uint256(-baseFlow);
            if (shortQ || shortB) return IOloBookBase.InsufficientBalance.selector;
        }
        (mv.acctQ, mv.walQ) = _split(flags, b.acctQ, quoteFlow);
        (mv.acctB, mv.walB) = _split(flags, b.acctB, baseFlow);
        return bytes4(0);
    }

    /// One operation by `a` on its slot `slot` of market `cc` (a version of market k's, current or older, or a C no
    /// market was listed with), run against the reference and the OLO EVM contract; returns the error both refused it
    /// with (0: none). The call names the market by `cc`'s key and carries its tag (OloOps.batchCalldata); a post rests
    /// in the market's current version whatever version `cc` is, so the slot it acts on is the current version's.
    function _op(uint256 k, MarketWord cc, bool listed, address a, uint16 slot, uint256[3] memory w)
        internal
        returns (bytes4 err)
    {
        uint256 v = !listed
            ? SlotRef.V_NONE
            : MarketWord.unwrap(cc) == MarketWord.unwrap(cs[k]) ? SlotRef.V_CURRENT : SlotRef.V_OLD;
        MarketWord slotC = (w[0] & 7) == OloOps.POST && v != SlotRef.V_NONE ? cs[k] : cc;
        (uint256 word, uint256 set) = book.batchOf(slotC, a, slot);
        SlotRef.Sums memory s;
        uint256 acted;
        (err, s, acted) = SlotRef.manageBatch(v == SlotRef.V_NONE ? slotC : _modelC(k, slotC), w, word, set, v);
        uint8 flags = uint8(w[0] >> 20);
        Bals memory b = _bals(a, k);
        Moves memory mv;
        // the fills settle at the share of the version the slot rests in, as the test recorded it
        if (err == bytes4(0)) err = _moves(mv, b, s, flags, vShares[k][_vi(k, slotC)]);
        if (err != bytes4(0)) {
            vm.prank(a);
            vm.expectRevert(err);
            _mb(cc, w);
            ++errs[err];
            (uint256 wordAfter, uint256 setAfter) = book.batchOf(slotC, a, slot);
            assertEq(wordAfter, word, "a refused operation leaves the main word");
            assertEq(setAfter, set, "a refused operation leaves the settlement word");
            return err;
        }
        vm.record();
        vm.recordLogs();
        vm.prank(a);
        _mb(cc, w);
        _checkWords(slotC, a, slot, set, s);
        _checkBatchEvent(slotC, a, slot, w[0] & 7, acted, s);
        Bals memory x = _bals(a, k);
        assertEq(int256(x.acctB) - int256(b.acctB), mv.acctB, "the base account");
        assertEq(int256(x.acctQ) - int256(b.acctQ), mv.acctQ, "the quote account");
        assertEq(int256(x.walB) - int256(b.walB), mv.walB, "the base wallet");
        assertEq(int256(x.walQ) - int256(b.walQ), mv.walQ, "the quote wallet");
        assertEq(x.pot - b.pot, mv.pot, "the pot");
        ++okKind[w[0] & 7];
        if (_mixed(s.next)) ++mixedOps;
        if ((w[0] & 7) == OloOps.MODIFY) {
            for (uint256 i; i < 4; ++i) {
                if (SlotRef.subAt(word, i) != 0 && SlotRef.bidAt(word, i) != SlotRef.bidAt(s.next, i)) ++liveFlips;
            }
        }
        // a cancel or a claim of an older version's slot that paid fills, during the fuzz (not `_finish`'s cancels)
        if (
            !finishing && v == SlotRef.V_OLD && (w[0] & 7) >= OloOps.CANCEL
                && BatchLib.filledMask(word, set) & acted != 0
        ) {
            ++oldSettles;
        }
        if (mv.walB != 0 || mv.walQ != 0) ++walletOps;
        roundings += 16;
    }

    /// The slot's words after an operation are the reference's; the main word was written, the settlement word
    /// exactly when it changed (in the accesses recorded since the operation).
    function _checkWords(MarketWord cc, address a, uint16 slot, uint256 set, SlotRef.Sums memory s) internal {
        uint256 key = OloSlots.batchSlot(cc, a, slot);
        (uint256 wordAfter, uint256 setAfter) = book.batchOf(cc, a, slot);
        assertEq(wordAfter, s.next, "the main word after");
        assertEq(setAfter, s.set, "the settlement word after");
        (, bytes32[] memory writes) = vm.accesses(address(book));
        assertTrue(_has(writes, key), "the main word written");
        assertEq(_has(writes, key + 1), s.set != set, "the settlement word written exactly when it changes");
        if (s.set == set) ++setKept;
    }

    /// One BatchUpdated: the maker, kind | acted 8-11 | slot 128-143 | market key 144-191 (the version, the id), and
    /// the words after.
    function _checkBatchEvent(MarketWord cc, address a, uint16 slot, uint256 kind, uint256 acted, SlotRef.Sums memory s)
        internal
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IOloBookBase.BatchUpdated.selector) continue;
            ++seen;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(a))), "BatchUpdated: the maker");
            (uint256 packed, uint256 word, uint256 set) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            uint256 key = MarketWord.unwrap(cc) >> 208;
            assertEq(packed, kind | (acted << 8) | (uint256(slot) << 128) | (key << 144), "BatchUpdated: packed");
            assertEq(word, s.next, "BatchUpdated: the main word");
            assertEq(set, s.set, "BatchUpdated: the settlement word");
        }
        assertEq(seen, 1, "one BatchUpdated");
    }

    /// A random amount of base wei for market k, worth at least its minQuote a few spacings from its center: the
    /// fixture 1 .. 1e15 (q 0 to 6), the 4-figure market 1e6 .. 1e16, the 18-decimal base 1e13 .. 1e23 (q 4 to 14).
    function _size(uint256 r, uint256 k) internal pure returns (uint256) {
        if (k == 0) return (1 + r % 9_999) * 10 ** ((r >> 16) % 12);
        if (k == 1) return (100 + r % 9_900) * 10 ** (4 + (r >> 16) % 9);
        return (100 + r % 9_900) * 10 ** (11 + (r >> 16) % 9);
    }

    /// The largest amount worth less than market k's minQuote at `tick` (a decade below 43): a x mantissa < minQuote x
    /// 10^(43 - d).
    function _belowMin(uint256 k, uint256 tick) internal view returns (uint256) {
        uint256 lim = cs[k].minQuote() * 10 ** (43 - SlotRef.decadeOf(tick));
        uint256 mant = SlotRef.mantissaOf(tick);
        return (lim + mant - 1) / mant - 1;
    }

    /// A random order for market k on side `bid`: mostly a maker's order 1 to 8 spacings from the market's center on
    /// its own side of it; now and then a zero order, a tick off the grid (0, past MAX_TICK) or off the spacing (on
    /// the 6-figure market the grid's bottom instead, worth nothing), an amount of no unit, just below or at
    /// minQuote's worth, the most units (2^30 - 1 at q 0 to 24) or the largest amount (2^112 - 1, q 25).
    function _order(uint256 r, uint256 k, bool bid) internal view returns (uint256 tick, uint256 amount) {
        uint256 sp = cs[k].spacing();
        uint256 off = sp * (1 + (r >> 8) % 8);
        tick = bid ? centers[k] - off : centers[k] + off;
        amount = _size(r >> 16, k);
        uint256 e = r % 48;
        if (e == 0) return (0, 0);
        if (e == 1) tick = 0;
        else if (e == 2) tick = SlotRef.MAX_TICK + 1 + (r >> 40) % (SlotRef.TICK_MASK - SlotRef.MAX_TICK);
        else if (e == 3) tick = sp > 1 ? tick + sp / 2 : 1;
        else if (e == 4) amount = 0;
        else if (e == 5) amount = _belowMin(k, tick);
        else if (e == 6) amount = _belowMin(k, tick) + 1;
        else if (e == 7) amount = UNITS * 10 ** ((r >> 40) % 25);
        else if (e == 8) amount = MAX_AMOUNT;
    }

    /// Settle flags: none half the time, WALLET, AUTO or both an eighth each, now and then a bit that means nothing.
    function _flags(uint256 r) internal pure returns (uint8) {
        uint256 f = r % 16;
        if (f < 8 || f == 15) return 0;
        if (f < 10) return 0x02;
        if (f < 12) return 0x04;
        if (f < 14) return 0x06;
        return [uint8(0x01), 0x08, 0x10, 0x80][(r >> 4) % 4];
    }

    /// A random operation's words on a slot holding `word` and `set`: post 5, replace 5, modify 5, cancel 2 and claim 3
    /// in 20, now and then an unknown kind (5-7); a random mask (0 now and then) and flags; up to four orders (a post
    /// or a replace leaves some indices empty, now and then all of them). A modify's order is now and then the
    /// sub-order's own tick and open amount (NoChange; for an empty sub-order the all-zero order), and a third of the
    /// modifies name live sub-orders only and keep each one's base (its base in units at its q, at a tick 1 to 8
    /// spacings from the center), which leaves the settlement word as it was when the q stays.
    function _params(uint256 r, uint256 k, uint256 word, uint256 set, uint16 slot)
        internal
        view
        returns (uint256[3] memory)
    {
        uint256 kind;
        uint256 kr = (r >> 3) % 20;
        if (r % 31 == 0) kind = 5 + (r >> 5) % 11; // 5 to 15: bit 3 set (the old rule's bid) among them
        else kind = kr < 5 ? 0 : kr < 10 ? 1 : kr < 15 ? 2 : kr < 17 ? 3 : 4;
        // the sides (a post's, a replace's and a modify's; a cancel and a claim read none): one side for every order a
        // third of the time, else random; a modify's half the time each live sub-order's own (each one named keeps its
        // side; an empty index's random), else random (turning some). Each order is priced for the side it rests on
        uint256 rf = _rnd(r, 0xf1);
        uint8 sides = rf % 3 == 0 ? ((r >> 8) & 1 == 1 ? 0xf : 0) : uint8((rf >> 8) % 16);
        if (kind == 2 && (rf >> 40) & 1 == 0) {
            uint256 live = _liveMask(word);
            sides = uint8((BatchView.bidMask(word) & live) | (sides & ~live & 0xf));
        }
        uint8 mask = uint8((r >> 9) % 16);
        uint8 flags = _flags(r >> 13);
        bool none = kind <= 1 && (r >> 20) % 8 == 0;
        bool keep = kind == 2 && (r >> 24) % 3 == 0;
        if (keep) {
            uint256 live = mask & _liveMask(word);
            mask = uint8(live != 0 ? live : _liveMask(word));
        }
        uint256[4] memory o;
        for (uint256 i; i < 4 && !none; ++i) {
            uint256 ri = _rnd(r, i);
            if (kind <= 1 && ri % 3 == 0) continue;
            uint256 sub = SlotRef.subAt(word, i);
            bool side = (sides >> i) & 1 == 1;
            (uint256 tick, uint256 amount) = _order(ri, k, side);
            uint256 unit = 10 ** ((sub >> 26) & SlotRef.Q_MASK);
            if (keep) {
                // its base at its unit, at a maker tick (its own now and then: with no fills to pay, NoChange)
                uint256 off = cs[k].spacing() * (1 + (ri >> 8) % 8);
                amount = SlotRef.baseAt(set, i) * unit;
                tick = side ? centers[k] - off : centers[k] + off;
            } else if (kind == 2 && (ri >> 200) % 5 == 0) {
                // the sub-order's tick and open amount, half the time with wei below its unit (stored the same when
                // the order's q is the sub-order's)
                tick = sub & SlotRef.TICK_MASK;
                amount = (sub >> 31) * unit + ((ri >> 100) & 1 == 0 ? 0 : (ri >> 101) % unit);
                if (amount > MAX_AMOUNT) amount = MAX_AMOUNT; // q 25: the most an amount holds, the same units
            }
            o[i] = OloOps.sub(tick, amount);
        }
        return OloOps.withSides(OloOps.batchW(uint8(kind), false, slot, flags, mask, o), sides);
    }

    /// The sub-orders holding an order, as a mask.
    function _liveMask(uint256 word) internal pure returns (uint256 live) {
        for (uint256 i; i < 4; ++i) {
            if (SlotRef.subAt(word, i) != 0) live |= 1 << i;
        }
    }

    /// A slot holding both sides: among its live sub-orders (an empty one has no side), some bids and some asks.
    function _mixed(uint256 word) internal pure returns (bool) {
        uint256 live = _liveMask(word);
        uint256 bids = (word >> SlotRef.SIDES) & live;
        return bids != 0 && bids != live;
    }

    /// A config word no market was listed with: a minQuote bit flipped (parameters nobody listed), or a listed
    /// market's parameters under an id never assigned.
    function _unlisted(MarketWord cc, uint256 r) internal pure returns (MarketWord) {
        uint256 w = MarketWord.unwrap(cc);
        if (r & 1 == 0) return MarketWord.wrap(w ^ (1 << 80));
        return MarketWord.wrap((w & ((1 << 224) - 1)) | (uint256(0xdead) << 224));
    }

    /// Market k's current version, or now and then (one in six, once it has more than one) an older one: a slot rests
    /// in the version current when it was posted, and settles and fills there.
    function _version(uint256 k, uint256 r) internal view returns (MarketWord) {
        uint256 n = vs[k].length;
        if (n == 1 || r % 6 != 0) return cs[k];
        return vs[k][(r >> 8) % (n - 1)];
    }

    function _manage(uint256 r) internal {
        uint256 k = r % 3;
        address a = mk[(r >> 2) & 1];
        uint16 slot = slotIds[(r >> 3) & 1];
        MarketWord cc = _version(k, _rnd(r, 0x7e));
        bool listed = (r >> 4) % 25 != 0;
        if (!listed) cc = _unlisted(cc, r >> 9);
        (uint256 word, uint256 set) = book.batchOf(cc, a, slot);
        _op(k, cc, listed, a, slot, _params(r >> 16, k, word, set, slot));
    }

    /// A claim of a slot of one of market k's older versions that has fills to pay (from a random start), through the
    /// reference; false when no older slot has any.
    function _claimOlder(uint256 k, uint256 r) internal returns (bool) {
        uint256 n = 4 * (vs[k].length - 1); // older versions x the four slots
        for (uint256 j; j < n; ++j) {
            uint256 x = (r + j) % n;
            if (!_hasFills(vs[k][x / 4], x % 4)) continue;
            _claimSlot(k, vs[k][x / 4], x % 4);
            return true;
        }
        return false;
    }

    function _hasFills(MarketWord cv, uint256 key) internal view returns (bool) {
        (address a, uint16 s) = _who(key);
        (uint256 word, uint256 set) = book.batchOf(cv, a, s);
        return BatchLib.filledMask(word, set) != 0;
    }

    function _claimSlot(uint256 k, MarketWord cv, uint256 key) internal {
        (address a, uint16 s) = _who(key);
        uint256[3] memory w = OloOps.maskW(OloOps.CLAIM, s, 0, 0);
        _op(k, cv, true, a, s, w);
    }

    /// The short maker's accounts drawn down to a random small balance each (below 1e12 wei), as a withdrawal would:
    /// its operations without flags then meet InsufficientBalance, and AUTO's debits run past the account into the
    /// wallet.
    function _drain(uint256 r) internal {
        address a = mk[1];
        MockERC20[3] memory ts = [base, quote, weth];
        for (uint256 i; i < 3; ++i) {
            uint256 held = _bal(a, ts[i]);
            uint256 keep = _rnd(r, i) % 1e12;
            if (held <= keep) continue;
            vm.prank(a);
            book.withdraw(address(ts[i]), held - keep);
        }
    }

    /// The owner changes market k's share: its next version (the share it has is no change, and nothing happens).
    function _setShare(uint256 r) internal {
        uint256 k = r % 3;
        uint256 share = (r >> 8) % 10_001;
        if (share == vShares[k][vShares[k].length - 1]) return;
        shares[k] = share;
        book.setMarketMakerShare(ids[k], uint16(share));
        _record(k, share, vFees[k][vFees[k].length - 1]);
        ++shareMoves;
    }

    /// The owner moves market k's fee, up to 1% either way and within 0 .. 100%: its next version (the fee it has is no
    /// change, and nothing happens).
    function _setFee(uint256 r) internal {
        uint256 k = r % 3;
        uint256 from = vFees[k][vFees[k].length - 1];
        uint256 step = (r >> 8) % 10_001;
        uint256 fee = (r >> 40) & 1 == 0 ? from + step : (step > from ? 0 : from - step);
        if (fee > 1_000_000) fee = 1_000_000;
        if (fee == from) return;
        book.setMarketFee(ids[k], uint24(fee), 0);
        _record(k, vShares[k][vShares[k].length - 1], fee);
        ++feeMoves;
    }

    // ------------------------------------------------------------------ takes

    /// A take's expected outcome, built group by group from the reference.
    struct Exp {
        bool buy;
        bool quoteMode;
        uint256 amount; // base wei, or quote wei in quote mode
        uint256 left; // base mode: the base still wanted
        uint256 base; // the base filled
        uint256 num; // the fills' exact quote (SlotRef.exact): Q = num / 10^23
        uint256 count; // the fills
        bytes list; // the closed segments
        bytes groups; // the open segment's groups
        bytes seg; // the open segment's fill records
        bytes fills; // the closed segments' fills, as the Take event logs them
        SlotRef.Budget budget; // quote mode
        uint256 ppm; // the fee of the version taken, as the test recorded it
    }

    /// The tick a taker saw sub-order i of a slot holding `word` at (an empty one: the market's center): its own, one
    /// either side, a stale one three spacings off either way (repriced since: worse is skipped, better fills at its
    /// own tick), a bound past every price, or 0 (a buy's bound of nothing, a sell's of anything).
    function _seen(uint256 r, uint256 word, uint256 i, bool buy, uint256 k) internal view returns (uint256) {
        uint256 t = SlotRef.subAt(word, i) & SlotRef.TICK_MASK;
        if (t == 0) t = centers[k];
        uint256 sp = cs[k].spacing();
        uint256 e = r % 9;
        if (e == 0) return buy ? SlotRef.MAX_TICK : 1;
        if (e == 1) return t - 1;
        if (e == 2) return t + 1;
        if (e == 3) return t - 3 * sp;
        if (e == 4) return t + 3 * sp;
        if (e == 5) return 0;
        return t;
    }

    /// A base-mode take's amount: everything named (2^112 - 1) now and then, or a tiny one (1 wei, which a bid below T
    /// prices under a quote wei; 1e4 .. 1e11 on the 18-decimal base, under a quote wei for a few units: a sell's fee
    /// passes its quote), else 1 .. 1e19 base wei (1e25 on the 18-decimal base).
    function _takeAmount(uint256 r, uint256 k) internal pure returns (uint256) {
        if (r % 8 == 0) return MAX_AMOUNT;
        if (r % 8 == 1 || r % 8 == 2) return k == 2 ? (1 + (r >> 8) % 9_999) * 10 ** (4 + (r >> 24) % 4) : 1;
        return (1 + (r >> 8) % 9_999) * 10 ** ((r >> 24) % (k == 2 ? 22 : 16));
    }

    /// A quote-mode take's budget: 1 wei (a buy pays at least a wei of quote and one of fee: nothing fills), 2 or 3
    /// wei (a sell's fill below a quote wei passes its fee), 2^112 - 1, or 1 .. 1e18 quote wei.
    function _budgetAmount(uint256 r) internal pure returns (uint256) {
        uint256 e = r % 10;
        if (e == 0) return 1;
        if (e == 1) return MAX_AMOUNT;
        if (e == 2) return 2 + (r >> 8) % 2;
        return (1 + (r >> 8) % 9_999) * 10 ** ((r >> 24) % 15);
    }

    /// The named sub-orders with units open on the taker's own side of a slot holding both sides: the take skips them.
    function _countOwnSkips(uint256 word, uint8 mask, bool buy) internal {
        for (uint256 i; i < 4; ++i) {
            if ((mask >> i) & 1 == 1 && SlotRef.subAt(word, i) >> 31 != 0 && SlotRef.bidAt(word, i) == buy) {
                ++ownSkips;
            }
        }
    }

    /// A group's fills into the expectation: the base, the exact quote, the count and the records.
    function _note(Exp memory x, address a, uint16 s, SlotRef.Fill[] memory fills) internal {
        for (uint256 j; j < fills.length; ++j) {
            uint256 amount = fills[j].units * 10 ** fills[j].q;
            x.base += amount;
            x.num += SlotRef.exact(amount, fills[j].tick);
            if (fills[j].q != 0) ++qFills;
        }
        x.count += fills.length;
        x.seg = bytes.concat(x.seg, SlotRef.records(a, s, fills));
    }

    /// Ends the open segment: its groups into the list (kind 1 | length 2), its fills, if any, into the expected
    /// fills (kind 1 | length 3).
    function _closeSegment(Exp memory x) internal pure {
        if (x.groups.length != 0) x.list = bytes.concat(x.list, OloOps.batchList(x.groups));
        if (x.seg.length != 0) {
            x.fills = bytes.concat(x.fills, abi.encodePacked(uint8(1), uint24(x.seg.length)), x.seg);
        }
        x.groups = "";
        x.seg = "";
    }

    function _take(uint256 r) internal {
        uint256 k = r % 3;
        // the version whose slots the take fills, named by the list's tag
        MarketWord cc = _version(k, _rnd(r, 0x7e));
        Exp memory x;
        x.buy = (r >> 2) & 1 == 1;
        x.quoteMode = (r >> 3) % 3 == 0;
        x.amount = x.quoteMode ? _budgetAmount(r >> 8) : _takeAmount(r >> 8, k);
        x.left = x.amount;
        x.ppm = vFees[k][_vi(k, cc)];
        if (x.quoteMode) x.budget = SlotRef.budget(x.buy, x.amount, x.ppm);
        // the reference's view of the slots, updated as its groups fill (a slot named twice reads its first fills)
        uint256[5] memory words;
        uint256[5] memory sets;
        for (uint256 key; key < 5; ++key) {
            (address a, uint16 s) = _who(key);
            (words[key], sets[key]) = book.batchOf(cc, a, s);
        }
        uint256 n = 1 + (r >> 120) % 5;
        for (uint256 g; g < n; ++g) {
            uint256 rg = _rnd(r, 100 + g);
            uint256 key = rg % 9 == 8 ? 4 : rg % 4;
            (address a, uint16 s) = _who(key);
            uint8 mask = uint8(1 + (rg >> 8) % 15);
            uint256[4] memory ticks;
            for (uint256 i; i < 4; ++i) {
                ticks[i] = _seen(rg >> (16 + 8 * i), words[key], i, x.buy, k);
            }
            x.groups = bytes.concat(x.groups, OloOps.slotGroup(a, s, mask, ticks));
            bool mixed = _mixed(words[key]);
            if (mixed) _countOwnSkips(words[key], mask, x.buy);
            SlotRef.Fill[] memory fills;
            if (x.quoteMode) {
                (words[key], fills) = SlotRef.fillGroupQuote(words[key], mask, ticks, x.budget);
            } else if (x.left != 0) {
                (words[key], x.left, fills) = SlotRef.fillGroup(words[key], mask, ticks, x.buy, x.left);
            }
            _note(x, a, s, fills);
            if (mixed && fills.length != 0) ++mixedFills;
            // now and then the segment ends here and the next groups open one of their own
            if (g + 1 < n && (rg >> 250) % 3 == 0) _closeSegment(x);
        }
        _closeSegment(x);
        if (x.quoteMode) assertEq(x.budget.num, x.num, "the budget's sum is the fills'");
        _runTake(k, cc, x, words, sets);
    }

    /// The take against the contract: the same verdict (a sell whose fee would reach its quote is refused,
    /// SellBelowFee), the same amounts, the taker's accounts, the slots' words and the Take event.
    function _runTake(uint256 k, MarketWord cc, Exp memory x, uint256[5] memory words, uint256[5] memory sets)
        internal
    {
        uint256 quoteX = SlotRef.quoteOf(x.num, x.buy);
        uint256 feeX = SlotRef.feeOf(x.num, x.ppm);
        uint256 params = x.quoteMode ? OloOps.quoteW(x.buy, x.amount, 0) : OloOps.takeW(x.buy, x.amount, 0);
        if (x.quoteMode && x.budget.refused) {
            // a sell's budget past 2^126, met at the first sub-order the walk reached
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.AmountOverflow.selector);
            book.take(OloOps.key(cc), x.list, OloOps.tagW(cc, params));
            return;
        }
        if (x.count != 0 && !x.buy && feeX >= quoteX) {
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.SellBelowFee.selector);
            book.take(OloOps.key(cc), x.list, OloOps.tagW(cc, params));
            ++sellBelowFee;
            return;
        }
        uint256 b0 = _bal(taker, bases[k]);
        uint256 q0 = _bal(taker, quote);
        vm.record();
        vm.recordLogs();
        vm.prank(taker);
        (uint256 got, uint256 paid) = book.take(OloOps.key(cc), x.list, OloOps.tagW(cc, params));
        assertEq(got, x.base, "the base filled");
        uint256 quoteAmount = x.count == 0 ? 0 : x.buy ? quoteX + feeX : quoteX - feeX;
        assertEq(paid, quoteAmount, "the quote with the fee");
        if (x.quoteMode) {
            assertLe(paid, x.amount, "the taker's amount within the budget");
            // where the budget stopped a sub-order short, one more unit there (exact quote c) would have broken it, so
            // what is left of A is less than c x (1 + f) + 1 for a buy and c x (1 - f) + 2 for a sell (OloBookTakes
            // note 4; a sell at a fee of 100% promises nothing here); in num's scale, times 10^6 x 10^23
            uint256 cut = x.budget.minCut;
            if (cut != type(uint256).max && (x.buy || x.ppm < 1e6)) {
                uint256 ppm = x.ppm;
                uint256 left = (x.amount - paid) * 1e29;
                if (x.buy) assertLt(left, cut * (1e6 + ppm) + 1e29, "a buy's leftover");
                else assertLt(left, cut * (1e6 - ppm) + 2e29, "a sell's leftover");
                ++budgetCuts;
            }
        }
        if (x.buy) {
            assertEq(q0 - _bal(taker, quote), paid, "the taker's quote paid");
            assertEq(_bal(taker, bases[k]) - b0, got, "the taker's base received");
        } else {
            assertEq(b0 - _bal(taker, bases[k]), got, "the taker's base paid");
            assertEq(_bal(taker, quote) - q0, paid, "the taker's quote received");
        }
        (, bytes32[] memory writes) = vm.accesses(address(book));
        for (uint256 key; key < 5; ++key) {
            (address a, uint16 s) = _who(key);
            (uint256 word, uint256 set) = book.batchOf(cc, a, s);
            assertEq(word, words[key], "a slot's main word after the take");
            assertEq(set, sets[key], "a slot's settlement word untouched");
            assertFalse(_has(writes, OloSlots.batchSlot(cc, a, s) + 1), "no settlement word written");
        }
        _checkTake(cc, x, quoteX, feeX);
        if (x.count != 0 && MarketWord.unwrap(cc) != MarketWord.unwrap(cs[k])) ++oldFills;
        if (x.count != 0) {
            if (x.quoteMode) ++quoteTakes;
            else ++baseTakes;
            roundings += 2;
        }
    }

    /// One Take event iff anything filled: the market, the taker, buyBase | count << 8, the base, the quote and the
    /// fee, and the fill records.
    function _checkTake(MarketWord cc, Exp memory x, uint256 quoteX, uint256 feeX) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IOloBookBase.Take.selector) continue;
            assertFalse(seen, "one Take");
            seen = true;
            assertEq(logs[i].topics[1], bytes32(MarketWord.unwrap(cc) >> 208), "Take: the market key");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(taker))), "Take: the taker");
            (uint256 packed, uint256 b_, uint256 q_, uint256 fee_, bytes memory fills) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bytes));
            assertEq(packed, (x.count << 8) | (x.buy ? 1 : 0), "Take: packed");
            assertEq(b_, x.base, "Take: the base");
            assertEq(q_, quoteX, "Take: the quote, the exact sum rounded once");
            assertEq(fee_, feeX, "Take: the fee on the exact sum, rounded up");
            assertEq(fills, x.fills, "Take: the fill records");
        }
        assertEq(seen, x.count != 0, "a Take iff fills");
    }

    // ------------------------------------------------------------------ the runs

    function _run(uint256 seed) internal {
        for (uint256 step; step < STEPS; ++step) {
            uint256 r = _rnd(seed, step);
            uint256 what = r % 16;
            if (what < 6) _take(r >> 4);
            else if (what == 6) _setShare(r >> 4);
            else if (what == 7 || what == 8) _drain(r >> 4);
            else if (what == 9) _setFee(r >> 4);
            // a claim of an older version's slot with fills to pay, when there is one, else as the others
            else if (what == 10 && _claimOlder((r >> 4) % 3, r >> 48)) continue;
            else _manage(r >> 4);
        }
    }

    /// Every slot holding a sub-order cancelled (through the reference, as any operation), then everyone leaves: each
    /// account withdrawn in full and the pots collected, weth by hand (OloBase's `_everyoneLeaves` knows base and
    /// quote). An OLO EVM contract owing more than it holds reverts here; base moves exactly (units x 10^q both ways),
    /// so none is left, and quote keeps at most what the roundings, each under a wei and in the contract's favour,
    /// kept.
    function _finish() internal {
        finishing = true;
        for (uint256 k; k < 3; ++k) {
            for (uint256 vi; vi < vs[k].length; ++vi) {
                MarketWord cv = vs[k][vi];
                for (uint256 key; key < 4; ++key) {
                    (address a, uint16 s) = _who(key);
                    (uint256 word,) = book.batchOf(cv, a, s);
                    if (word >> 2 == 0) continue;
                    assertEq(_op(k, cv, true, a, s, OloOps.maskW(OloOps.CANCEL, s, 0, 0xf)), bytes4(0), "cancelled");
                }
            }
        }
        for (uint256 i; i <= makers.length; ++i) {
            address a = i < makers.length ? makers[i] : taker;
            uint256 held = _bal(a, weth);
            vm.prank(a);
            book.withdraw(address(weth), held);
        }
        book.collectFees(address(weth));
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0, "no base left");
        assertEq(weth.balanceOf(address(book)), 0, "no weth left");
        assertLe(quoteLeft, roundings, "quote: at most a wei per rounding left");
    }

    /// `_run` in a call of its own, so its memory is its own: the coverage test runs 40 seeds in one test, and the
    /// memory each leaves behind would make the next one dearer, past the gas limit.
    function runSeed(uint256 seed) external {
        _run(seed);
    }

    function testFuzz_slots_match_the_reference(uint256 seed) public {
        _run(seed);
        _finish();
    }

    /// The fuzz reaches what it means to: every kind of operation, every error an operation can meet, the settlement
    /// word left unwritten, wallet and AUTO settlements (AUTO short of the account too), takes that fill in both modes,
    /// q > 0 fills, quote-mode takes the budget stopped short (their leftover's bound checked), sells refused for
    /// their fee, share and fee changes, and older versions' slots filled and settled with fills (before `_finish`).
    function test_reference_reaches_every_op_and_error() public {
        for (uint256 s; s < 40; ++s) {
            this.runSeed(uint256(keccak256(abi.encode("slot ref versions", s))));
        }
        _finish();
        string[5] memory kinds = ["posts", "replaces", "modifies", "cancels", "claims"];
        for (uint256 kind; kind < 5; ++kind) {
            emit log_named_uint(kinds[kind], okKind[kind]);
        }
        bytes4[12] memory sels = [
            IOloBookBase.MarketFrozen.selector,
            IOloBookBase.BadBatch.selector,
            IOloBookBase.BadFlags.selector,
            IOloBookBase.SlotBusy.selector,
            IOloBookBase.ZeroSize.selector,
            IOloBookBase.NoOrder.selector,
            IOloBookBase.NothingToClaim.selector,
            IOloBookBase.UnknownMarket.selector,
            IOloBookBase.NoChange.selector,
            IOloBookBase.TickOutOfRange.selector,
            IOloBookBase.SizeOutOfRange.selector,
            IOloBookBase.InsufficientBalance.selector
        ];
        string[12] memory names = [
            "MarketFrozen",
            "BadBatch",
            "BadFlags",
            "SlotBusy",
            "ZeroSize",
            "NoOrder",
            "NothingToClaim",
            "UnknownMarket",
            "NoChange",
            "TickOutOfRange",
            "SizeOutOfRange",
            "InsufficientBalance"
        ];
        for (uint256 i; i < sels.length; ++i) {
            emit log_named_uint(names[i], errs[sels[i]]);
        }
        emit log_named_uint("settlement word left", setKept);
        emit log_named_uint("wallet settlements", walletOps);
        emit log_named_uint("AUTO pulls", autoPulls);
        emit log_named_uint("base-mode takes that filled", baseTakes);
        emit log_named_uint("quote-mode takes that filled", quoteTakes);
        emit log_named_uint("q > 0 fills", qFills);
        emit log_named_uint("budget cuts", budgetCuts);
        emit log_named_uint("sells below their fee", sellBelowFee);
        emit log_named_uint("older versions' settles", oldSettles);
        emit log_named_uint("older versions' fills", oldFills);
        emit log_named_uint("share changes", shareMoves);
        emit log_named_uint("fee changes", feeMoves);
        emit log_named_uint("operations leaving both sides", mixedOps);
        emit log_named_uint("groups filling a slot of both sides", mixedFills);
        emit log_named_uint("own-side sub-orders skipped", ownSkips);
        emit log_named_uint("live sub-orders a modify turned", liveFlips);
        assertGe(mixedOps, 10, "operations leaving both sides");
        assertGe(mixedFills, 10, "groups filling a slot of both sides");
        assertGe(ownSkips, 10, "own-side sub-orders skipped");
        assertGe(liveFlips, 3, "live sub-orders a modify turned");
        assertGe(shareMoves, 3, "share changes");
        assertGe(feeMoves, 3, "fee changes");
        assertGe(oldSettles, 3, "older versions' settles");
        assertGe(oldFills, 3, "older versions' fills");
        for (uint256 kind; kind < 5; ++kind) {
            assertGe(okKind[kind], 3, kinds[kind]);
        }
        for (uint256 i; i < sels.length; ++i) {
            assertGe(errs[sels[i]], 3, names[i]);
        }
        assertGe(setKept, 3, "settlement word left");
        assertGe(walletOps, 3, "wallet settlements");
        assertGe(autoPulls, 3, "AUTO pulls");
        assertGe(baseTakes, 10, "base-mode takes");
        assertGe(quoteTakes, 5, "quote-mode takes");
        assertGe(qFills, 3, "q > 0 fills");
        assertGe(budgetCuts, 3, "budget cuts");
        assertGe(sellBelowFee, 3, "sells below their fee");
    }

    // ------------------------------------------------------------------ directed

    /// A modify whose order for an empty sub-order is all zero (tick 0, amount 0) is NoChange: the walk compares the
    /// order with the sub-order's tick and open amount, both zero for an empty one, and NoChange outranks the tick's
    /// check. So a modify cannot name an empty index to leave it empty, not even beside a real change (the whole
    /// operation is refused), and a zero order for a live sub-order is TickOutOfRange: a modify neither empties a
    /// sub-order nor keeps one empty; a cancel empties. The contract as it stands; the reference
    /// agrees at every step.
    function test_modify_zero_order_on_an_empty_sub_order_is_no_change() public {
        address a = mk[0];
        uint256[4] memory two = [OloOps.sub(T + 1, 5 * LOT), OloOps.sub(T + 2, 5 * LOT), 0, 0];
        assertEq(_op(0, c, true, a, 3, OloOps.batchW(OloOps.POST, false, 3, 0, 0, two)), bytes4(0), "posted");
        uint256[4] memory none;
        assertEq(
            _op(0, c, true, a, 3, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x4, none)),
            IOloBookBase.NoChange.selector,
            "a zero order naming the empty sub-order 2"
        );
        uint256[4] memory change = [OloOps.sub(T + 5, 6 * LOT), 0, 0, 0];
        assertEq(
            _op(0, c, true, a, 3, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x5, change)),
            IOloBookBase.NoChange.selector,
            "beside a real change of sub-order 0: the whole modify refused"
        );
        assertEq(
            _op(0, c, true, a, 3, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x1, none)),
            IOloBookBase.TickOutOfRange.selector,
            "a zero order naming the live sub-order 0"
        );
        uint256[4] memory add;
        add[2] = OloOps.sub(T + 3, 2 * LOT);
        assertEq(
            _op(0, c, true, a, 3, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x4, add)), bytes4(0), "an order adds it"
        );
        assertEq(_op(0, c, true, a, 3, OloOps.maskW(OloOps.CANCEL, 3, 0, 0x4)), bytes4(0), "a cancel empties it");
        (uint256 word, uint256 set) = book.batchOf(c, a, 3);
        assertEq(BatchView.openOf(word, 0), 5 * LOT, "sub-order 0 as posted");
        assertEq(BatchView.tickOf(word, 2), 0, "sub-order 2 empty");
        assertEq(BatchView.filledOf(word, set, 2), 0, "nothing to claim on it (its base is left over)");
    }

    /// A modify rests every index it names on its side s_i: a live sub-order whose side differs is turned, a changed
    /// order even at the same tick and amount (settled on its old side, escrowed on the new one), with fills or
    /// without; the same orders on their current sides again are NoChange. The reference agrees at every step.
    function test_modify_turns_live_sub_orders() public {
        address a = mk[0];
        uint256[4] memory o = [OloOps.sub(T - 1, 5 * LOT), OloOps.sub(T + 1, 5 * LOT), OloOps.sub(T + 2, 5 * LOT), 0];
        assertEq(
            _op(0, c, true, a, 3, OloOps.withFlips(OloOps.batchW(OloOps.POST, false, 3, 0, 0, o), 0x1)),
            bytes4(0),
            "a bid and two asks"
        );
        o[2] = 0;
        uint256[3] memory turn = OloOps.withFlips(OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x3, o), 0x2);
        assertEq(_op(0, c, true, a, 3, turn), bytes4(0), "the same ticks and amounts, the bid an ask, the ask a bid");
        (uint256 word,) = book.batchOf(c, a, 3);
        assertEq(word >> SlotRef.SIDES, 0x2, "D_0 cleared (an ask), D_1 set (a bid)");
        assertEq(_op(0, c, true, a, 3, turn), IOloBookBase.NoChange.selector, "on their sides now: NoChange");
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(a, 3, 0x2, T + 1)),
            OloOps.tagW(c, OloOps.takeW(false, 2 * LOT, 0))
        );
        uint256[4] memory back;
        back[1] = OloOps.sub(T + 1, 3 * LOT);
        assertEq(
            _op(0, c, true, a, 3, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x2, back)),
            bytes4(0),
            "the part-filled bid turned back to an ask at its tick and open amount: its fills paid in base"
        );
        (word,) = book.batchOf(c, a, 3);
        assertEq(word >> SlotRef.SIDES, 0, "every sub-order an ask: one side again");
    }

    /// A modify's order equal to its sub-order's tick and open amount: NoChange while the sub-order has no fills to
    /// pay; with fills the sub-order rests again and they are paid, as a claim pays them, and
    /// the same order again is NoChange. The reference agrees at every step.
    function test_modify_same_order_with_fills_pays_them() public {
        address a = mk[0];
        uint256[4] memory two = [OloOps.sub(T + 1, 5 * LOT), OloOps.sub(T + 2, 5 * LOT), 0, 0];
        assertEq(_op(0, c, true, a, 3, OloOps.batchW(OloOps.POST, false, 3, 0, 0, two)), bytes4(0), "posted");
        uint256[4] memory same = [OloOps.sub(T + 1, 5 * LOT), 0, 0, 0];
        assertEq(
            _op(0, c, true, a, 3, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x1, same)),
            IOloBookBase.NoChange.selector,
            "no fills: nothing to pay"
        );
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(a, 3, 1, T + 1)),
            OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0))
        );
        same[0] = OloOps.sub(T + 1, 3 * LOT);
        uint256 q0 = _bal(a, quote);
        assertEq(
            _op(0, c, true, a, 3, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x1, same)),
            bytes4(0),
            "the tick and what is open, with fills: paid"
        );
        uint256 makerFee = PriceGrid.feeDown(2 * LOT, T + 1, 50) * vShares[0][vShares[0].length - 1] / 10_000;
        assertEq(_bal(a, quote) - q0, _qd(2 * LOT, T + 1) + makerFee, "the fills' proceeds and the fee's maker part");
        (uint256 word, uint256 set) = book.batchOf(c, a, 3);
        assertEq(BatchView.openOf(word, 0), 3 * LOT, "what was open rests on");
        assertEq(BatchView.filledOf(word, set, 0), 0, "nothing left to claim");
        assertEq(
            _op(0, c, true, a, 3, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x1, same)),
            IOloBookBase.NoChange.selector,
            "paid: the same again"
        );
    }

    /// Quote mode fills right up to its budget's rule, equality included, where random amounts almost never land: at
    /// T (P = 1 exactly) at 50 ppm, a sell of A = 19,999 quote wei fills 20,000 base wei of a bid (Q x (1 - f) = 19,999
    /// = A) and receives exactly A (20,000 less a fee of 1); a buy of A = 20,001 fills 20,000 of an ask and pays
    /// exactly A (20,000 and a fee of 1; 20,001 would cost 20,003). The reference finds the same units.
    function test_quote_mode_fills_to_the_budget_exactly() public {
        address a = mk[0];
        uint256[4] memory one = [OloOps.sub(T, 40_000), 0, 0, 0];
        uint256[4] memory ticks = [T, T, T, T];
        assertEq(_op(0, c, true, a, 3, OloOps.batchW(OloOps.POST, true, 3, 0, 0, one)), bytes4(0), "a bid at T");
        assertEq(_op(0, c, true, a, 9, OloOps.batchW(OloOps.POST, false, 9, 0, 0, one)), bytes4(0), "an ask at T");
        (uint256 word,) = book.batchOf(c, a, 3);
        (, SlotRef.Fill[] memory fills) = SlotRef.fillGroupQuote(word, 1, ticks, SlotRef.budget(false, 19_999, 50));
        assertEq(fills[0].units, 20_000, "the reference's sell: Q x (1 - f) = A");
        vm.prank(taker);
        (uint256 got, uint256 paid) = book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(a, 3, 1, T)),
            OloOps.tagW(c, OloOps.quoteW(false, 19_999, 0))
        );
        assertEq(got, 20_000, "the sell's base");
        assertEq(paid, 19_999, "the sell receives exactly A");
        (word,) = book.batchOf(c, a, 9);
        (, fills) = SlotRef.fillGroupQuote(word, 1, ticks, SlotRef.budget(true, 20_001, 50));
        assertEq(fills[0].units, 20_000, "the reference's buy: ceil(Q) + ceil(Q x f) = A");
        vm.prank(taker);
        (got, paid) = book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(a, 9, 1, T)),
            OloOps.tagW(c, OloOps.quoteW(true, 20_001, 0))
        );
        assertEq(got, 20_000, "the buy's base");
        assertEq(paid, 20_001, "the buy pays exactly A");
    }

    /// The amounts at their bounds: four sub-orders of the most units a sub-order holds, 2^30 - 1, at the top of the
    /// grid (P = 999,996e30 .. 999,999e30 quote wei per base wei), at q 0, 8, 16 and 24, then all four at q 24 (1.07e33
    /// base wei each, the largest 2^30 - 1 units below 2^112), asks then bids, on a market of no minQuote at a 0.3% fee
    /// with a 70% maker share. Each slot is posted, taken whole and claimed through the wallets (a slot's quote, up to
    /// 4.3e69 wei, is past what an account holds), and every flow is exact, computed here: decade 73 prices whole
    /// numbers of quote wei, so nothing rounds, and the contract ends holding nothing.
    function test_amounts_at_the_bounds() public {
        uint32 mb = book.listMarketQuote(address(base), address(quote), 3000, 6, 0, 0);
        book.setMarketMakerShare(mb, 7_000);
        MarketWord cb = book.configOf(mb); // the version at 70%
        address a = address(0xB0B);
        makers.push(a);
        base.mint(a, 1e40);
        quote.mint(a, 1e72);
        base.mint(taker, 1e40);
        quote.mint(taker, 1e72);
        vm.startPrank(a);
        base.approve(address(book), type(uint256).max);
        quote.approve(address(book), type(uint256).max);
        vm.stopPrank();
        for (uint256 round; round < 4; ++round) {
            uint256[4] memory qs = round < 2 ? [uint256(0), 8, 16, 24] : [uint256(24), 24, 24, 24];
            _boundsRound(cb, a, round % 2 == 1, qs);
        }
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0, "no base left");
        assertEq(quoteLeft, 0, "no quote left: nothing rounded");
    }

    /// The amounts of `_boundsRound`'s slot: per token the sums of its four sub-orders, and the fee, summed per
    /// sub-order as the settle floors it (exact here).
    struct Bound {
        uint256 baseSum;
        uint256 quoteSum;
        uint256 feeSum;
        uint256 wB;
        uint256 wQ;
    }

    function _boundsRound(MarketWord cb, address a, bool bid, uint256[4] memory qs) internal {
        uint16 slot = 5;
        uint256[4] memory o;
        Bound memory x;
        for (uint256 i; i < 4; ++i) {
            uint256 amount = UNITS * 10 ** qs[i];
            o[i] = OloOps.sub(SlotRef.MAX_TICK - i, amount);
            // decade 73: P = mantissa x 10^30, mantissa 999,999 - i
            uint256 value = amount * (999_999 - i) * 1e30;
            x.baseSum += amount;
            x.quoteSum += value;
            x.feeSum += value * 3000 / 1e6;
        }
        // posted through the wallet: an ask escrows its amount, a bid its quote, exact
        x.wB = base.balanceOf(a);
        x.wQ = quote.balanceOf(a);
        vm.prank(a);
        _mb(cb, OloOps.batchW(OloOps.POST, bid, slot, 0x02, 0, o));
        assertEq(x.wB - base.balanceOf(a), bid ? 0 : x.baseSum, "post: the base escrowed");
        assertEq(x.wQ - quote.balanceOf(a), bid ? x.quoteSum : 0, "post: the quote escrowed");
        (uint256 word, uint256 set) = book.batchOf(cb, a, slot);
        for (uint256 i; i < 4; ++i) {
            (uint256 tick, uint256 q, uint256 open) = BatchView.subOf(word, i);
            assertEq(tick, SlotRef.MAX_TICK - i, "post: the tick");
            assertEq(q, qs[i], "post: q");
            assertEq(open, UNITS, "post: the most units");
            assertEq(BatchView.baseOf(set, i), UNITS, "post: the base");
        }
        _boundsTake(cb, a, bid, slot, x);
        // claimed through the wallet: the fills' proceeds and the fee's maker part; the pot the rest
        uint256 makerPart = x.feeSum * 7_000 / 10_000;
        uint256 pot0 = _pot(quote);
        x.wB = base.balanceOf(a);
        x.wQ = quote.balanceOf(a);
        vm.prank(a);
        _mb(cb, OloOps.maskW(OloOps.CLAIM, slot, 0x02, 0));
        assertEq(base.balanceOf(a) - x.wB, bid ? x.baseSum : 0, "claim: the base paid");
        assertEq(quote.balanceOf(a) - x.wQ, (bid ? 0 : x.quoteSum) + makerPart, "claim: the quote paid");
        assertEq(_pot(quote) - pot0, x.feeSum - makerPart, "claim: the pot");
        (word, set) = book.batchOf(cb, a, slot);
        assertEq(word, 2, "claimed whole: every sub-order emptied, its side with it (USED alone)");
        assertEq(
            set >> 255, 1, "claimed whole: the settlement word keeps USED (its bases left over, counting for nothing)"
        );
        for (uint256 i; i < 4; ++i) {
            assertEq(BatchView.filledOf(word, set, i), 0, "claimed whole: nothing left to claim");
        }
    }

    /// The slot taken whole through the taker's wallet: every unit, the quote exact and the fee on it exact.
    function _boundsTake(MarketWord cb, address a, bool bid, uint16 slot, Bound memory x) internal {
        uint256 tB = base.balanceOf(taker);
        uint256 tQ = quote.balanceOf(taker);
        (, uint256 set) = book.batchOf(cb, a, slot);
        bytes memory list = OloOps.batchList(OloOps.slotGroupAt(a, slot, 0xf, bid ? 1 : SlotRef.MAX_TICK));
        vm.prank(taker);
        (uint256 got, uint256 paid) =
            book.take(OloOps.key(cb), list, OloOps.tagW(cb, OloOps.takeW(!bid, x.baseSum, OloOps.WALLET)));
        uint256 fee = x.quoteSum * 3000 / 1e6;
        assertEq(fee * 1e6, x.quoteSum * 3000, "the fee exact");
        assertEq(fee, x.feeSum, "the take's fee is the settles'");
        assertEq(got, x.baseSum, "take: every unit");
        if (bid) {
            assertEq(paid, x.quoteSum - fee, "take: a sell receives the quote less the fee");
            assertEq(tB - base.balanceOf(taker), x.baseSum, "take: the base pulled");
            assertEq(quote.balanceOf(taker) - tQ, paid, "take: the quote pushed");
        } else {
            assertEq(paid, x.quoteSum + fee, "take: a buy pays the quote and the fee");
            assertEq(base.balanceOf(taker) - tB, x.baseSum, "take: the base pushed");
            assertEq(tQ - quote.balanceOf(taker), paid, "take: the quote pulled");
        }
        (uint256 word, uint256 setAfter) = book.batchOf(cb, a, slot);
        for (uint256 i; i < 4; ++i) {
            assertEq(BatchView.openOf(word, i), 0, "take: nothing open");
            assertEq(BatchView.filledOf(word, setAfter, i), UNITS * 10 ** BatchLibQ.qOf(word, i), "take: filled whole");
        }
        assertEq(setAfter, set, "take: the settlement word untouched");
    }

    /// A WALLET post writes the slot before it pulls the escrow, so a take re-entering from the token's transferFrom
    /// would fill a slot not yet funded; the lock refuses it (Locked), and likewise inside a WALLET cancel's push. A
    /// replace by the same orders nets every token to zero: no transfer, so no call back.
    function test_wallet_batch_reentry_is_locked() public {
        ReentrantToken rt = new ReentrantToken();
        MarketWord cr = book.configOf(book.listMarketQuote(address(rt), address(quote), 50, 6, 1, 0));
        address a = mk[0];
        rt.mint(a, 1e30);
        vm.prank(a);
        rt.approve(address(book), type(uint256).max);
        bytes memory list = OloOps.batchList(OloOps.slotGroupAt(a, 0, 0x7, T + 3));
        bytes memory reenter =
            abi.encodeCall(book.take, (OloOps.key(cr), list, OloOps.tagW(cr, OloOps.takeW(true, 15 * LOT, 0))));
        rt.arm(address(book), reenter);
        uint256 w0 = rt.balanceOf(a);
        vm.prank(a);
        _mb(cr, OloOps.ladderW(OloOps.POST, false, 0, 0x02, T + 1, 5 * LOT, 3, 1));
        assertEq(rt.attempts(), 1, "the escrow's pull called back");
        assertFalse(rt.lastOk());
        assertEq(bytes4(rt.lastRevert()), IOloBookBase.Locked.selector, "post: locked");
        assertEq(w0 - rt.balanceOf(a), 15 * LOT, "the escrow pulled");
        // a replace by the same orders nets every token to zero: no transfer at all, so no call back
        rt.arm(address(book), reenter);
        vm.prank(a);
        _mb(cr, OloOps.ladderW(OloOps.REPLACE, false, 0, 0x02, T + 1, 5 * LOT, 3, 1));
        assertEq(rt.attempts(), 1, "no transfer, no call back");
        assertEq(w0 - rt.balanceOf(a), 15 * LOT);
        // a cancel of two pushes their refund to the wallet: the take inside the push is locked out
        vm.prank(a);
        _mb(cr, OloOps.maskW(OloOps.CANCEL, 0, 0x02, 0x6));
        assertEq(rt.attempts(), 2, "the refund's push called back");
        assertFalse(rt.lastOk());
        assertEq(bytes4(rt.lastRevert()), IOloBookBase.Locked.selector, "cancel: locked");
        assertEq(w0 - rt.balanceOf(a), 5 * LOT, "the refund of two sub-orders of 5 LOT");
        (uint256 word, uint256 set) = book.batchOf(cr, a, 0);
        assertEq(BatchView.openOf(word, 0), 5 * LOT, "sub-order 0 untouched: nothing filled");
        assertEq(BatchView.filledOf(word, set, 0), 0);
        assertEq(BatchView.tickOf(word, 1) + BatchView.tickOf(word, 2), 0, "sub-orders 1 and 2 cancelled");
    }
}

/// A sub-order's q from the main word (BatchView reads the tick and the units; the bounds test wants q apart).
library BatchLibQ {
    function qOf(uint256 word, uint256 i) internal pure returns (uint256 q) {
        (, q,) = BatchView.subOf(word, i);
    }
}
