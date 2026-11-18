// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {ReentrantToken} from "./utils/HostileTokens.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {SafeTransfer} from "../src/libraries/SafeTransfer.sol";

using MarketLib for MarketWord;

/// An exact model of the money flows (ported to base-wei amounts and the one grid): pool orders
/// (place, cancel, claim, modify), takes (base and quote mode, buy and sell, through the accounts and the wallet,
/// fill-or-kill with a tolerance), takeThenRest (its rest, and a remainder worth less than minQuote left with the
/// taker), accounts (deposit, withdraw, withdrawTo, the fee pots and their collection), the multicall (PLACE,
/// CANCEL, CLAIM, MODIFY, DEPOSIT and WITHDRAW over none, one or two markets, each named in the header by its key K or
/// by a version's C, settled by none, WALLET, AUTO or both) and the owner's share and fee changes (setMarketMakerShare,
/// setMarketFee with warmed positions): each the market's next version, while the orders resting in the versions before
/// keep their C, fill at its fee, settle at its share, cancel and claim, and refuse a modify (MarketFrozen). Every entry
/// names its market as an upstream does: K, and the version's tag in the params (a take's and a takeThenRest's for
/// their fills, a cancel's, a claim's, a modify's); a place sends C now and then (UnknownMarket).
/// Random sequences run on three markets of 6/6, 18/6 and 8/6 decimals, each near a decade boundary: P = 1 at the
/// bottom of decade 38, ETH at $1,000 (the bottom of decade 29) and $2,500, BTC at $100,000 (the bottom of decade 41);
/// amounts with q 0 to 13. The model keeps every version's C and pool words (up to NV versions; past that a change it
/// would make is sent as one that changes nothing, NoChange), every account, pot and wallet (the OLO EVM contract's own
/// balance and the fee recipient's too) and derives each operation's outcome, revert included, from its own arithmetic:
/// per order quote rounded down out and up in and the fee floored at the fee of the order's version, split at that
/// version's maker share at the settle; a take's exact sum
/// rounded once; quote mode's units from its spec (a buy the most that keeps what it pays, the quote and the fee each
/// rounded up, within the amount; a sell the most whose exact quote less the fee is within it). After every step the
/// contract equals the model, and at the end everyone settles and leaves.
contract OloMoneyModelTest is OloBase {
    /// The markets' significant figures; the subclasses below run the same model at 5, 4 and 3.
    function _sigFigs() internal pure virtual returns (uint8) {
        return PriceGrid.MAX_SIG_FIGS;
    }

    // ------------------------------------------------------------------ markets and actors

    uint256 constant NM = 3; // markets
    uint256 constant NV = 12; // the versions the model keeps: the three listings' and nine changes
    uint256 constant NT = 4; // tokens: base (6 decimals), quote (6), weth (18), wbtc (8)
    uint256 constant NA = 4; // actors: three makers and the taker; anyone makes and takes
    uint256 constant NH = 6; // wallets: the actors', the OLO EVM contract's, the fee recipient's (this contract)
    uint256 constant BOOK_H = 4;
    uint256 constant FEE_H = 5;
    uint256 constant QT = 1; // every market's quote token
    uint256 constant NPOS = 12; // the positions a place names
    uint256 constant SCAN = NPOS + 16; // and the ones its probes (up to 15) reach: the positions the model keeps
    uint32 constant UNUSED = 999; // a position nobody writes
    uint256 constant STEPS = 100;

    /// ETH at $1,000 (P = 1e-9, the bottom of decade 29) and at $2,500; BTC at $100,000 (P = 1,000, the bottom of 41).
    uint256 constant ETH_1000 = 26_100_000;
    uint256 constant ETH_2500 = 26_250_000;
    uint256 constant BTC_100K = 36_900_000;

    MockERC20 weth;
    MockERC20 wbtc;
    MockERC20[NT] tok;
    uint256[NT] tid;
    uint256 tokenCount_;
    MarketWord[NM] mc; // the listings' C as setUp (or a configs run) leaves them: the model's first versions
    uint256[NM] mBase; // the market's base token (its index in `tok`)
    uint256[NM] mMin; // minQuote, quote wei (K's: every version's)
    uint256[NM] mCenter; // the tick its prices straddle
    uint256[NM] mFar; // a second center inside a decade (0: none)
    uint256 S; // the maker tick spacing
    address[NA] who;
    address[NH] holder;

    function setUp() public {
        _deployWith(_sigFigs());
        S = _spacing();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        tok[0] = base;
        tok[1] = quote;
        tok[2] = weth;
        tok[3] = wbtc;
        // M0: 6/6 at P = 1 across decades 37 and 38, 0.3%, minQuote 1 wei; M1: ETH/USDC across decades 28 and 29 and
        // at $2,500, 77 ppm, minQuote 0.001 USDC (1e12 wei of ETH at $1,000); M2: BTC/USDC across decades 40 and 41,
        // 50%, no minQuote. Maker shares 100%, 70% and 0.
        _listAs(0, base, 0, 3000, 1, T, 0);
        _listAs(1, weth, 2, 77, 1e3, ETH_1000, ETH_2500);
        _listAs(2, wbtc, 3, 500_000, 0, BTC_100K, 0);
        _shareOf(1, 7000);
        _shareOf(2, 0);
        who[0] = _maker();
        who[1] = _maker();
        who[2] = _maker();
        who[3] = taker;
        // every actor's accounts a few of the largest orders deep (an order of up to ~1e18 base wei at P = 1, ~1e22 wei
        // of ETH, ~1e14 sat), so debits fall short now and then and AUTO pulls from the wallet
        for (uint256 a; a < NA; ++a) {
            holder[a] = who[a];
            weth.mint(who[a], 1e36);
            wbtc.mint(who[a], 1e36);
            vm.startPrank(who[a]);
            weth.approve(address(book), type(uint256).max);
            wbtc.approve(address(book), type(uint256).max);
            book.deposit(address(weth), 1e23);
            book.deposit(address(wbtc), 1e15);
            if (who[a] == taker) {
                book.deposit(address(base), 1e19);
                book.deposit(address(quote), 1e19);
            } else {
                book.withdraw(address(base), 1e24 - 1e19); // `_maker` deposited 1e24 of each
                book.withdraw(address(quote), 1e24 - 1e19);
            }
            vm.stopPrank();
        }
        holder[BOOK_H] = address(book);
        holder[FEE_H] = address(this); // the fee recipient OloBase deploys the contract with
        for (uint256 k; k < NT; ++k) {
            tid[k] = book.tokenId(address(tok[k]));
        }
        tokenCount_ = book.tokenCount();
    }

    function _listAs(uint256 mi, MockERC20 b, uint256 bIdx, uint24 fee, uint96 minQuote, uint256 ctr, uint256 far)
        internal
    {
        mc[mi] = book.configOf(book.listMarketQuote(address(b), address(quote), fee, _sigFigs(), minQuote, 0));
        mBase[mi] = bIdx;
        mMin[mi] = minQuote;
        mCenter[mi] = ctr;
        mFar[mi] = far;
    }

    /// The owner sets market `mi`'s share, its next version, which `mc[mi]` follows (none when it has the share).
    function _shareOf(uint256 mi, uint256 bps) internal {
        if (mc[mi].makerBps() == bps) return;
        book.setMarketMakerShare(mc[mi].marketId(), uint16(bps));
        mc[mi] = book.configOf(mc[mi].marketId());
    }

    // ------------------------------------------------------------------ the reference arithmetic
    // Every tick the model meets is in decades 28 .. 41, below 43, so a quote is a fraction: amount x mantissa x
    // 10^(d - 43). The model keeps it exact as an integer scaled by SCALE = 10^(43 - LOW), LOW = 28 the lowest decade
    // used: X(amount, tick) = amount x mantissa x 10^(d - 28), the quote x 10^15. A take's exact quote is the sum of
    // its fills' X, rounded once at the end. Bounds: amounts below 2^90 (the generators' largest is about 2^87; a take
    // of 2^100 fills at most the open amounts it reaches), the mantissa below 2^20, 10^(d - 28) at most 10^13 < 2^44,
    // so one X is below 2^154 and a take's sum (8 fills at most) below 2^157; times a fee in ppm (below 2^20) below
    // 2^177; a sell's budget A x 10^6 x 10^15, with A below 2^112, is below 2^182, and sum x (10^6 - fee) below 2^177;
    // minQuote x 10^15 below 2^146. Everything fits 256 bits.

    uint256 constant LOW = 28;
    uint256 constant SCALE = 1e15; // 10^(43 - LOW)
    uint256 constant TOP_TICK = 74 * 900_000 - 1;
    uint256 constant U30 = (1 << 30) - 1;
    uint256 constant TICK_M = (1 << 26) - 1;

    /// The exact quote of `amount` base wei at `tick`, times 10^15.
    function _x(uint256 amount, uint256 tick) internal pure returns (uint256) {
        uint256 d = tick / 900_000;
        require(d >= LOW && d < 43, "model: a decade outside 28 .. 42");
        return amount * (100_000 + tick % 900_000) * 10 ** (d - LOW);
    }

    function _divUp(uint256 x, uint256 d) internal pure returns (uint256) {
        return x / d + (x % d == 0 ? 0 : 1);
    }

    function _qDown(uint256 amount, uint256 tick) internal pure returns (uint256) {
        return _x(amount, tick) / SCALE;
    }

    function _qUp(uint256 amount, uint256 tick) internal pure returns (uint256) {
        return _divUp(_x(amount, tick), SCALE);
    }

    function _feeDown(uint256 amount, uint256 tick, uint256 ppm) internal pure returns (uint256) {
        return _x(amount, tick) * ppm / (SCALE * 1e6);
    }

    /// An order's q (the smallest with amount / 10^q below 2^30) and units.
    function _units(uint256 amount) internal pure returns (uint256 q, uint256 units) {
        while (amount / 10 ** q > U30) {
            ++q;
        }
        units = amount / 10 ** q;
    }

    /// A maker's tick: from the makers' floor (3,600,000, decade 4) to the grid's top, and on the spacing.
    function _makerTick(uint256 tick) internal view returns (bool) {
        return tick >= 3_600_000 && tick <= TOP_TICK && tick % S == 0;
    }

    /// `stored` rests on market `mi` at `tick`: at least a unit, worth at least minQuote exactly.
    function _worth(uint256 mi, uint256 tick, uint256 stored) internal view returns (bool) {
        if (stored == 0) return false;
        return mMin[mi] == 0 || _x(stored, tick) >= mMin[mi] * SCALE;
    }

    // ------------------------------------------------------------------ pool words
    // tick 0-25 | q 26-32 | open 33-62 | filled 63-92 | isBid 93 | USED 94 | owner 96-255 (IOloBook.orderWord)

    function _fresh(uint256 tick, uint256 q, uint256 units, bool bid, address o) internal pure returns (uint256) {
        return tick | (q << 26) | (units << 33) | (bid ? 1 << 93 : 0) | (1 << 94) | (uint256(uint160(o)) << 96);
    }

    function _live(uint256 w) internal pure returns (bool) {
        return (w >> 33) & ((1 << 60) - 1) != 0;
    }

    /// The word dead: the side, USED and the owner kept.
    function _dead(uint256 w) internal pure returns (uint256) {
        return w & ~uint256((1 << 93) - 1);
    }

    function _ownerOf(uint256 w) internal pure returns (address) {
        return address(uint160(w >> 96));
    }

    // ------------------------------------------------------------------ the model's state

    /// Everything the contract holds that the model keeps, compared after every step.
    struct State {
        uint256[SCAN][NV] word; // pool words, per version
        uint256[NT][NA] acct; // accounts
        uint256[NT] pot; // the fee pots
        uint256[NT][NH] wal; // token balances: actors, the contract, the fee recipient
        uint256 nv; // the versions so far: the listings' (one per market), then one per change
        uint256[NV] vm; // a version's market
        uint256[NV] vc; // its C (its fee and maker share in the tag)
        uint256[NM] cur; // a market's current version
    }

    /// A multicall's or a flagged operation's ledger, as OloBookAssets keeps it: per token touched, the orders' net
    /// flow, the account's own flow and the wallet's.
    struct Ledger {
        bool direct;
        uint256 n;
        uint256[4] tok;
        int256[4] maker;
        int256[4] credit;
        int256[4] wallet;
    }

    /// One step: who calls, the call, and what the model expects of it (a revert's selector, or 0 and the returns).
    struct Plan {
        address sender; // pranked; 0 for this contract (the OLO EVM contract's owner)
        bytes data;
        bytes4 err;
        uint256 nRet;
        uint256 ret0;
        uint256 ret1;
        uint256 ret2; // a takeThenRest's: the amount rested and its order id
        uint256 ret3;
        uint256 note; // coverage: NOTE_* bits
    }

    // coverage notes
    uint256 constant NOTE_TWO_DECADES = 0; // a take filled across a decade boundary
    uint256 constant NOTE_QUOTE_FILL = 1; // a quote-mode take filled
    uint256 constant NOTE_Q_FILL = 2; // a fill of a q > 0 order
    uint256 constant NOTE_AUTO_PULL = 3; // AUTO pulled a shortfall from the wallet
    uint256 constant NOTE_RESTED = 4; // a takeThenRest rested its remainder
    uint256 constant NOTE_BELOW_MIN = 5; // a takeThenRest's remainder below minQuote stayed with the taker
    uint256 constant NOTE_FOK_PASS = 6; // fill-or-kill passed with something left
    uint256 constant NOTE_FEE_SPLIT = 7; // a settle split a fee between the maker and the pot
    uint256 constant NOTE_PROBED = 8; // a place landed past its named position
    uint256 constant NOTE_SELL_FILL = 9; // a sell filled
    uint256 constant NOTE_BUY_FILL = 10; // a buy filled
    uint256 constant NOTE_OLD_FILL = 11; // a take filled an older version's orders, at that version's fee
    uint256 constant NOTE_OLD_SETTLE = 12; // a settle paid an older version's fills, at its fee and maker share
    uint256 constant NOTE_REST_CROSS = 13; // a takeThenRest filled in an older version and rested in the current one
    uint256 constant NOTE_MC_KEY = 14; // a multicall op on a market its header names by K
    uint256 constant NOTE_MC_TAG = 15; // a multicall op on a market its header names by a version's C
    uint256 constant NOTE_MC_OLD = 16; // a multicall CANCEL or CLAIM of an older version's order (a header C)
    uint256 constant NOTE_WARMED = 17; // a fee change warmed positions of its new version
    uint256 constant NOTES = 18;

    /// The step kinds: 0-4 place, 5 cancel, 6 claim, 7 modify, 8-11 take, 12-13 takeThenRest, 14-15 multicall, 16
    /// maker share, 17 fee, 18-19 deposit or withdraw, 20 collectFees.
    uint256 constant KINDS = 21;
    uint256[KINDS] okKind;
    uint256[KINDS] revKind;
    uint256[NOTES] seen;
    uint256 fokReverts;
    uint256 sellBelowFee;
    uint256 frozenReverts; // MarketFrozen: a modify, or a PLACE or MODIFY under a header C, of an older version
    uint256 unknownReverts; // UnknownMarket: a place that sent C, not K

    /// `s` copied into `t` (the versions `s` has: a new version's words are `_newVersion`'s to set). A run keeps two
    /// States and swaps them, so a step allocates none (a fresh State a step ran the memory past the gas limit).
    function _copyInto(State memory t, State memory s) internal pure {
        t.nv = s.nv;
        for (uint256 v; v < s.nv; ++v) {
            for (uint256 p; p < SCAN; ++p) {
                t.word[v][p] = s.word[v][p];
            }
            t.vm[v] = s.vm[v];
            t.vc[v] = s.vc[v];
        }
        for (uint256 mi; mi < NM; ++mi) {
            t.cur[mi] = s.cur[mi];
        }
        for (uint256 k; k < NT; ++k) {
            t.pot[k] = s.pot[k];
            for (uint256 a; a < NA; ++a) {
                t.acct[a][k] = s.acct[a][k];
            }
            for (uint256 h; h < NH; ++h) {
                t.wal[h][k] = s.wal[h][k];
            }
        }
    }

    /// The model at the start: no order, each market's listing its one version, the balances as setUp left them.
    function _init() internal view returns (State memory s) {
        s.nv = NM;
        for (uint256 mi; mi < NM; ++mi) {
            s.vm[mi] = mi;
            s.vc[mi] = MarketWord.unwrap(mc[mi]);
            s.cur[mi] = mi;
        }
        for (uint256 k; k < NT; ++k) {
            s.pot[k] = book.balanceOf(tid[k], address(0));
            for (uint256 a; a < NA; ++a) {
                s.acct[a][k] = book.balanceOf(tid[k], who[a]);
            }
            for (uint256 h; h < NH; ++h) {
                s.wal[h][k] = tok[k].balanceOf(holder[h]);
            }
        }
    }

    function _wordAt(State memory s, uint256 v, uint256 pos) internal pure returns (uint256) {
        return pos < SCAN ? s.word[v][pos] : 0;
    }

    /// Version `v`'s C, its market's key K (what every entry names the market by), its fee in ppm.
    function _c(State memory s, uint256 v) internal pure returns (MarketWord) {
        return MarketWord.wrap(s.vc[v]);
    }

    function _key(State memory s, uint256 v) internal pure returns (MarketWord) {
        return OloOps.key(_c(s, v));
    }

    function _fee(State memory s, uint256 v) internal pure returns (uint256) {
        return (s.vc[v] >> 188) & 0xfffff; // C's fee field, 188-207
    }

    function _isCur(State memory s, uint256 v) internal pure returns (bool) {
        return s.cur[s.vm[v]] == v;
    }

    /// An order id as `place` and `takeThenRest` return it: the tag of version `v` (C's bits 174-223) at 206-255 above
    /// the position, the params' shape of a cancel or a claim of the order.
    function _orderIdAt(State memory s, uint256 v, uint256 landed) internal pure returns (uint256) {
        return ((s.vc[v] >> 174) << 206) | landed;
    }

    /// One of market `mi`'s versions: its current one half the time, else any of them (the current one included).
    function _verOf(State memory s, uint256 mi, uint256 r) internal pure returns (uint256) {
        if (r % 2 == 0) return s.cur[mi];
        uint256 n;
        for (uint256 v; v < s.nv; ++v) {
            if (s.vm[v] == mi) ++n;
        }
        uint256 pick = (r >> 1) % n;
        for (uint256 v; v < s.nv; ++v) {
            if (s.vm[v] != mi) continue;
            if (pick == 0) return v;
            --pick;
        }
        revert("model: no version");
    }

    // ------------------------------------------------------------------ money moves

    /// OloBookAssets._moveAccount: a debit needs the balance, a credit stays within 2^128 - 1.
    function _move(State memory s, uint256 a, uint256 k, int256 flow) internal pure returns (bytes4) {
        if (flow < 0) {
            uint256 amt = uint256(-flow);
            if (s.acct[a][k] < amt) return IOloBookBase.InsufficientBalance.selector;
            s.acct[a][k] -= amt;
        } else if (flow > 0) {
            uint256 b = s.acct[a][k] + uint256(flow);
            if (b > type(uint128).max) return IOloBookBase.AmountOverflow.selector;
            s.acct[a][k] = b;
        }
        return 0;
    }

    /// A pull from actor `a`'s wallet into the contract.
    function _pull(State memory s, uint256 a, uint256 k, uint256 amt) internal pure returns (bytes4) {
        if (s.wal[a][k] < amt) return SafeTransfer.TransferFailed.selector;
        s.wal[a][k] -= amt;
        s.wal[BOOK_H][k] += amt;
        return 0;
    }

    /// A push from the contract to holder `h`: the contract must hold it (else it owes more than it has).
    function _push(State memory s, uint256 h, uint256 k, uint256 amt) internal pure returns (bytes4) {
        require(s.wal[BOOK_H][k] >= amt, "model: the book cannot pay");
        s.wal[BOOK_H][k] -= amt;
        s.wal[h][k] += amt;
        return 0;
    }

    /// The fee a settle's fills earned, split at the maker share of the order's version `v` (C's bits 174-187): the
    /// maker's part returned, the rest to the quote token's pot.
    function _split(State memory s, Plan memory p, uint256 v, uint256 fee) internal pure returns (uint256 makerPart) {
        makerPart = fee * ((s.vc[v] >> 174) & 0x3fff) / 10_000;
        if (makerPart != fee) {
            s.pot[QT] += fee - makerPart;
            if (makerPart != 0) p.note |= 1 << NOTE_FEE_SPLIT;
        }
        if (!_isCur(s, v)) p.note |= 1 << NOTE_OLD_SETTLE;
    }

    /// The ledger's entry of token `k`: the one in use, or the next; a fifth token is TooManyTokens.
    function _entry(Ledger memory l, uint256 k) internal pure returns (bool ok, uint256 i) {
        for (; i < l.n; ++i) {
            if (l.tok[i] == k) return (true, i);
        }
        if (l.n == 4) return (false, 0);
        l.tok[i] = k;
        ++l.n;
        return (true, i);
    }

    /// An order's flow: on the account now (direct), or into the ledger.
    function _flow(State memory s, Ledger memory l, uint256 a, uint256 k, int256 f) internal pure returns (bytes4) {
        if (l.direct) return _move(s, a, k, f);
        (bool ok, uint256 i) = _entry(l, k);
        if (!ok) return IOloBookBase.TooManyTokens.selector;
        l.maker[i] += f;
        return 0;
    }

    /// OloBookAssets._commit: per entry the orders' net flow to the account or the wallet by the flags (AUTO takes a
    /// debit from the account first, as far as it reaches, the rest from the wallet), the credits applied, the pulls;
    /// then every push.
    function _commit(State memory s, Plan memory p, Ledger memory l, uint256 a, uint256 flags)
        internal
        pure
        returns (bytes4 err)
    {
        bool toWallet = flags & 2 != 0;
        bool auto_ = flags & 4 != 0;
        for (uint256 i; i < l.n; ++i) {
            uint256 k = l.tok[i];
            int256 m = l.maker[i];
            int256 c = l.credit[i];
            int256 w = l.wallet[i];
            if (m > 0) {
                if (toWallet) w += m;
                else c += m;
            } else if (m < 0) {
                uint256 need = uint256(-m);
                if (auto_) {
                    uint256 bal = s.acct[a][k];
                    uint256 avail = c >= 0 ? bal + uint256(c) : (bal > uint256(-c) ? bal - uint256(-c) : 0);
                    uint256 fromCredit = avail < need ? avail : need;
                    c -= int256(fromCredit);
                    w -= int256(need - fromCredit);
                    if (need > fromCredit) p.note |= 1 << NOTE_AUTO_PULL;
                } else if (toWallet) {
                    w += m;
                } else {
                    c += m;
                }
            }
            if (c != 0) {
                err = _move(s, a, k, c);
                if (err != 0) return err;
            }
            if (w < 0) {
                err = _pull(s, a, k, uint256(-w));
                if (err != 0) return err;
            }
            l.wallet[i] = w;
        }
        for (uint256 i; i < l.n; ++i) {
            if (l.wallet[i] > 0) _push(s, a, l.tok[i], uint256(l.wallet[i]));
        }
    }

    // ------------------------------------------------------------------ the orders

    /// OloBookOrders._placeOp in version `v`: the checks in the contract's order (the tick and the size on the market's
    /// key, then the version current: a multicall's PLACE under a header C of an older version is MarketFrozen; the
    /// place entry and a rest always rest in the current one), the first free position of pos .. pos + probes, the
    /// order's word and its escrow (an ask its stored base, a bid its stored amount's quote rounded up).
    function _mPlace(
        State memory s,
        uint256 v,
        uint256 a,
        bool bid,
        uint256 tick,
        uint256 amount,
        uint256 pos,
        uint256 flags
    ) internal view returns (bytes4 err, uint256 landed, uint256 escrow) {
        if (!_makerTick(tick)) return (IOloBookBase.TickOutOfRange.selector, 0, 0);
        (uint256 q, uint256 units) = _units(amount);
        uint256 stored = units * 10 ** q;
        if (!_worth(s.vm[v], tick, stored)) return (IOloBookBase.SizeOutOfRange.selector, 0, 0);
        if (!_isCur(s, v)) return (IOloBookBase.MarketFrozen.selector, 0, 0);
        if (flags & 0x0f != 0) return (IOloBookBase.BadFlags.selector, 0, 0);
        uint256 probes = flags >> 4;
        landed = pos;
        while (_live(s.word[v][landed])) {
            if (probes == 0) return (IOloBookBase.SlotBusy.selector, 0, 0);
            --probes;
            ++landed;
        }
        s.word[v][landed] = _fresh(tick, q, units, bid, who[a]);
        escrow = bid ? _qUp(stored, tick) : stored;
    }

    /// A cancel in version `v`: the fills' proceeds and the maker's part of their fee (floored at the version's fee,
    /// then split at its share), the open amount refunded (a bid's quote rounded down); the word dead.
    function _mCancel(State memory s, Plan memory p, Ledger memory l, uint256 v, uint256 a, uint256 pos)
        internal
        view
        returns (bytes4 err)
    {
        uint256 w = _wordAt(s, v, pos);
        if (!_live(w)) return IOloBookBase.NoOrder.selector;
        if (_ownerOf(w) != who[a]) return IOloBookBase.NotOrderOwner.selector;
        s.word[v][pos] = _dead(w);
        uint256 tick = w & TICK_M;
        uint256 unit = 10 ** ((w >> 26) & 0x7f);
        uint256 open = ((w >> 33) & U30) * unit;
        uint256 filled = ((w >> 63) & U30) * unit;
        uint256 quoteAmt;
        uint256 baseAmt;
        if ((w >> 93) & 1 == 1) {
            quoteAmt = _qDown(open, tick);
            baseAmt = filled;
        } else {
            quoteAmt = _qDown(filled, tick);
            baseAmt = open;
        }
        if (filled != 0) {
            uint256 fee = _feeDown(filled, tick, _fee(s, v));
            if (fee != 0) quoteAmt += _split(s, p, v, fee);
        }
        if (quoteAmt != 0) err = _flow(s, l, a, QT, int256(quoteAmt));
        if (err == 0 && baseAmt != 0) err = _flow(s, l, a, mBase[s.vm[v]], int256(baseAmt));
    }

    /// A claim in version `v`: the fills' proceeds (an ask's quote rounded down, a bid's base) and the maker's part of
    /// their fee (the version's fee and share); the order rests on with its open units, or is dead with none.
    function _mClaim(State memory s, Plan memory p, Ledger memory l, uint256 v, uint256 a, uint256 pos)
        internal
        view
        returns (bytes4 err, uint256 proceeds)
    {
        uint256 w = _wordAt(s, v, pos);
        if (!_live(w)) return (IOloBookBase.NoOrder.selector, 0);
        if (_ownerOf(w) != who[a]) return (IOloBookBase.NotOrderOwner.selector, 0);
        uint256 filledUnits = (w >> 63) & U30;
        if (filledUnits == 0) return (IOloBookBase.NothingToClaim.selector, 0);
        s.word[v][pos] = (w >> 33) & U30 == 0 ? _dead(w) : w & ~(U30 << 63);
        uint256 tick = w & TICK_M;
        uint256 filled = filledUnits * 10 ** ((w >> 26) & 0x7f);
        uint256 quoteAmt;
        uint256 baseAmt;
        uint256 fee = _feeDown(filled, tick, _fee(s, v));
        if (fee != 0) quoteAmt = _split(s, p, v, fee);
        if ((w >> 93) & 1 == 1) {
            proceeds = filled;
            baseAmt = filled;
        } else {
            proceeds = _qDown(filled, tick);
            quoteAmt += proceeds;
        }
        if (quoteAmt != 0) err = _flow(s, l, a, QT, int256(quoteAmt));
        if (err == 0 && baseAmt != 0) err = _flow(s, l, a, mBase[s.vm[v]], int256(baseAmt));
    }

    /// A modify in version `v`, which must be the current one (MarketFrozen, checked first): the fills paid as a claim's, the new amount rested as its own units and q at the new tick on the
    /// order's side, only the net escrow moved (a bid: the old open amount's quote rounded down back, the new one's
    /// rounded up out).
    function _mModify(
        State memory s,
        Plan memory p,
        Ledger memory l,
        uint256 v,
        uint256 a,
        uint256 pos,
        uint256 newTick,
        uint256 newAmount
    ) internal view returns (bytes4 err) {
        if (!_isCur(s, v)) return IOloBookBase.MarketFrozen.selector;
        uint256 w = _wordAt(s, v, pos);
        if (!_live(w)) return IOloBookBase.NoOrder.selector;
        if (_ownerOf(w) != who[a]) return IOloBookBase.NotOrderOwner.selector;
        if (!_makerTick(newTick)) return IOloBookBase.TickOutOfRange.selector;
        (uint256 q, uint256 units) = _units(newAmount);
        uint256 stored = units * 10 ** q;
        if (!_worth(s.vm[v], newTick, stored)) return IOloBookBase.SizeOutOfRange.selector;
        uint256 tick = w & TICK_M;
        uint256 unit = 10 ** ((w >> 26) & 0x7f);
        uint256 open = ((w >> 33) & U30) * unit;
        uint256 filled = ((w >> 63) & U30) * unit;
        // kept, the same tick and open amount: NoChange with no fills to pay, else the modify pays them and the order
        // rests on, its escrow untouched (a claim's)
        bool kept = newTick == tick && stored == open;
        if (kept && filled == 0) return IOloBookBase.NoChange.selector;
        bool bid = (w >> 93) & 1 == 1;
        s.word[v][pos] = _fresh(newTick, q, units, bid, who[a]);
        uint256 fee;
        uint256 proceeds;
        if (filled != 0) {
            fee = _feeDown(filled, tick, _fee(s, v));
            if (fee != 0) fee = _split(s, p, v, fee);
            proceeds = bid ? filled : _qDown(filled, tick);
        }
        int256 quoteFlow;
        int256 baseFlow;
        if (bid) {
            baseFlow = int256(proceeds);
            // a kept bid moves no escrow; otherwise the old open amount refunded down, the new one escrowed up
            quoteFlow = kept ? int256(fee) : int256(fee + _qDown(open, tick)) - int256(_qUp(stored, newTick));
        } else {
            quoteFlow = int256(proceeds + fee);
            baseFlow = int256(open) - int256(stored);
        }
        if (quoteFlow != 0) err = _flow(s, l, a, QT, quoteFlow);
        if (err == 0 && baseFlow != 0) err = _flow(s, l, a, mBase[s.vm[v]], baseFlow);
    }

    // ------------------------------------------------------------------ the takes

    /// A take list: its pool entries (position, the tick the taker saw) and its bytes (one or two segments).
    struct List {
        uint256 n;
        uint32[8] pos;
        uint256[8] bound;
        bytes data;
    }

    /// What a walk filled: base wei, the exact quote x 10^15, the fills, and for coverage the decades met.
    struct Walk {
        uint256 filled;
        uint256 sum;
        uint256 count;
        uint256 lowD;
        uint256 highD;
        bool qFill;
        bool refused; // a quote-mode sell's budget past 2^126, refused at the first order the walk reaches
    }

    /// A sell's 1 - f in ppm, its budget's divisor: 10^6 - ppm, and 1 at a fee of 100% (a sell there receives nothing
    /// whatever it fills; its budget is taken as at 1 ppm below).
    function _sellRate(uint256 ppm) internal pure returns (uint256) {
        return ppm < 1e6 ? 1e6 - ppm : 1;
    }

    /// What a buy of exact quote sum / 10^15 pays at a fee of `ppm`: the quote and the fee, each rounded up.
    function _buyPays(uint256 ppm, uint256 sum) internal pure returns (uint256) {
        return _divUp(sum, SCALE) + _divUp(sum * ppm, SCALE * 1e6);
    }

    /// Quote mode's units at an order (OloBookTakes note 4, from its spec rather than its closed form): a buy the most
    /// x <= open that keeps what it pays, ceil(Q) + ceil(Q x f), within A (it grows with Q, so a binary search finds
    /// it); a sell the most with Q x (10^6 - fee) <= A x 10^6, so that floor(Q) - ceil(Q x f) stays within A. `per` is
    /// a unit's exact quote x 10^15.
    function _quoteUnits(uint256 ppm, bool buy, uint256 amount, uint256 sum, uint256 per, uint256 open)
        internal
        pure
        returns (uint256 x)
    {
        if (!buy) {
            uint256 capN = amount * 1e6 * SCALE;
            uint256 y = _sellRate(ppm);
            require(sum * y <= capN, "model: a sell past its budget");
            x = (capN - sum * y) / (per * y);
            return x < open ? x : open;
        }
        require(_buyPays(ppm, sum) <= amount, "model: a buy past its budget");
        uint256 hi = open; // the answer is in [x, hi]
        while (x < hi) {
            uint256 mid = (x + hi + 1) / 2;
            if (_buyPays(ppm, sum + mid * per) <= amount) x = mid;
            else hi = mid - 1;
        }
    }

    /// The walk, entry by entry in the list's order, on the model's words (a position named twice reads its fills):
    /// an order fills while it has open units, is on the other side, and is at the entry's tick or better for the
    /// taker, at its own tick, in whole units: base mode min(open, floor(remaining / 10^q)) (the walk stops once
    /// nothing remains); quote mode the most units its budget allows (`_quoteUnits`).
    function _walk(State memory s, uint256 v, bool buy, uint256 amount, bool quoteMode, List memory l)
        internal
        pure
        returns (Walk memory w)
    {
        uint256 remaining = amount;
        w.lowD = type(uint256).max;
        for (uint256 i; i < l.n; ++i) {
            if (!quoteMode && remaining == 0) break;
            uint256 word = _wordAt(s, v, l.pos[i]);
            uint256 open = (word >> 33) & U30;
            uint256 tick = word & TICK_M;
            if (open == 0 || ((word >> 93) & 1 == 1) == buy) continue;
            if (buy ? tick > l.bound[i] : tick < l.bound[i]) continue;
            uint256 q = (word >> 26) & 0x7f;
            uint256 unit = 10 ** q;
            uint256 x;
            if (quoteMode) {
                // OloBookTakes note 4: a sell's budget whose whole part passes 2^126 is refused here, at the first order
                // the walk reaches, whether or not a unit of it is within the budget
                if (!buy && amount * 1e6 / _sellRate(_fee(s, v)) > 1 << 126) {
                    w.refused = true;
                    break;
                }
                x = _quoteUnits(_fee(s, v), buy, amount, w.sum, _x(unit, tick), open);
            } else {
                x = remaining / unit;
                if (x > open) x = open;
            }
            if (x == 0) continue;
            s.word[v][l.pos[i]] = word - (x << 33) + (x << 63);
            uint256 amt = x * unit;
            if (!quoteMode) remaining -= amt;
            w.filled += amt;
            w.sum += _x(amt, tick);
            ++w.count;
            uint256 d = tick / 900_000;
            if (d < w.lowD) w.lowD = d;
            if (d > w.highD) w.highD = d;
            if (q != 0) w.qFill = true;
        }
    }

    /// OloBookTakes._finishTake: the quote rounded once (a buy up, a sell down), the fee on the exact sum rounded up,
    /// SellBelowFee, fill-or-kill on what is left (base mode the base not filled, quote mode the amount less what is
    /// paid or received), and the settlement with a takeThenRest's rest escrow joined to what the taker pays.
    function _finish(
        State memory s,
        Plan memory p,
        uint256 v,
        uint256 a,
        bool buy,
        uint256 amount,
        uint8 mode,
        uint256 maxLeft,
        Walk memory w,
        uint256 escrow
    ) internal view returns (bytes4 err) {
        bool fok = mode & 0x80 != 0;
        bool wallet = mode & 1 != 0;
        uint256 bT = mBase[s.vm[v]];
        p.nRet = 2;
        if (w.count == 0) {
            if (fok && amount > maxLeft) return IOloBookBase.FokNotFilled.selector;
            if (escrow == 0) return 0;
            uint256 k = buy ? QT : bT;
            return wallet ? _pull(s, a, k, escrow) : _move(s, a, k, -int256(escrow));
        }
        uint256 quoteX = buy ? _divUp(w.sum, SCALE) : w.sum / SCALE;
        uint256 feeX = _divUp(w.sum * _fee(s, v), SCALE * 1e6); // the fee of the version the params' tag names
        uint256 qa;
        if (buy) {
            qa = quoteX + feeX;
        } else {
            if (feeX >= quoteX) return IOloBookBase.SellBelowFee.selector;
            qa = quoteX - feeX;
        }
        bool quoteMode = mode & 2 != 0;
        // OloBookTakes note 4: a quote-mode take never pays or receives more than its amount
        if (quoteMode) assertLe(qa, amount, "quote mode within its amount");
        if (fok) {
            uint256 left = quoteMode ? amount - qa : amount - w.filled;
            if (left > maxLeft) return IOloBookBase.FokNotFilled.selector;
            if (left != 0) p.note |= 1 << NOTE_FOK_PASS;
        }
        p.ret0 = w.filled;
        p.ret1 = qa;
        if (w.highD != w.lowD) p.note |= 1 << NOTE_TWO_DECADES;
        if (quoteMode) p.note |= 1 << NOTE_QUOTE_FILL;
        p.note |= 1 << (buy ? NOTE_BUY_FILL : NOTE_SELL_FILL);
        if (w.qFill) p.note |= 1 << NOTE_Q_FILL;
        if (!_isCur(s, v)) p.note |= 1 << NOTE_OLD_FILL;
        (uint256 kIn, uint256 inAmt, uint256 kOut, uint256 outAmt) =
            buy ? (QT, qa + escrow, bT, w.filled) : (bT, w.filled + escrow, QT, qa);
        if (wallet) {
            err = _pull(s, a, kIn, inAmt);
            if (err == 0) err = _push(s, a, kOut, outAmt);
            return err;
        }
        if (s.acct[a][kIn] < inAmt) return IOloBookBase.InsufficientBalance.selector;
        s.acct[a][kIn] -= inAmt;
        return _move(s, a, kOut, int256(outAmt));
    }

    // ------------------------------------------------------------------ the entries

    /// `place` on market `mi`, named by its key K (or, when `sentC`, by its current C: UnknownMarket once the tick and
    /// the size pass): the order in the market's current version, then its escrow by the flags (none from the account,
    /// WALLET from the wallet, AUTO from the account as far as it reaches and the rest from the wallet). Returns the
    /// order id: the version's tag above the position.
    function _ePlace(
        State memory s,
        Plan memory p,
        uint256 mi,
        uint256 a,
        bool bid,
        uint256 tick,
        uint256 amount,
        uint32 pos,
        uint8 flags,
        bool sentC
    ) internal view returns (bytes4 err) {
        uint256 v = s.cur[mi];
        if (sentC) {
            if (!_makerTick(tick)) return IOloBookBase.TickOutOfRange.selector;
            (uint256 q, uint256 units) = _units(amount);
            if (!_worth(mi, tick, units * 10 ** q)) return IOloBookBase.SizeOutOfRange.selector;
            return IOloBookBase.UnknownMarket.selector;
        }
        uint256 landed;
        uint256 escrow;
        (err, landed, escrow) = _mPlace(s, v, a, bid, tick, amount, pos, flags & ~uint8(6));
        if (err != 0) return err;
        if (landed != pos) p.note |= 1 << NOTE_PROBED;
        uint256 k = bid ? QT : mBase[mi];
        p.nRet = 1;
        p.ret0 = _orderIdAt(s, v, landed);
        if (flags & 6 == 0) return _move(s, a, k, -int256(escrow));
        if (flags & 4 != 0) {
            uint256 bal = s.acct[a][k];
            if (bal >= escrow) {
                s.acct[a][k] = bal - escrow;
                return 0;
            }
            s.acct[a][k] = 0;
            p.note |= 1 << NOTE_AUTO_PULL;
            return _pull(s, a, k, escrow - bal);
        }
        return _pull(s, a, k, escrow);
    }

    uint256 constant OP_CANCEL = 1;
    uint256 constant OP_CLAIM = 2;
    uint256 constant OP_MODIFY = 3;

    /// `cancel`, `claim` and `modify` of an order in version `v`: the flags checked, the op's flows moved on the
    /// accounts (no flags) or settled by the flags (`_settleFlows`).
    function _eOrder(
        State memory s,
        Plan memory p,
        uint256 op,
        uint256 v,
        uint256 a,
        uint32 pos,
        uint256 newTick,
        uint256 newAmount,
        uint8 flags
    ) internal view returns (bytes4 err) {
        if (flags & ~uint8(6) != 0) return IOloBookBase.BadFlags.selector;
        Ledger memory l;
        l.direct = flags == 0;
        if (op == OP_CANCEL) {
            err = _mCancel(s, p, l, v, a, pos);
        } else if (op == OP_CLAIM) {
            p.nRet = 1;
            (err, p.ret0) = _mClaim(s, p, l, v, a, pos);
        } else {
            err = _mModify(s, p, l, v, a, pos, newTick, newAmount);
        }
        if (err != 0 || l.direct) return err;
        return _commit(s, p, l, a, flags);
    }

    /// `take` in version `v` (the tag its params carry): the mode bits (WALLET, QUOTE, FOK), a zero amount, the walk
    /// of the version's orders and its end at the version's fee.
    function _eTake(
        State memory s,
        Plan memory p,
        uint256 v,
        uint256 a,
        bool buy,
        uint256 amount,
        uint8 mode,
        uint256 maxLeft,
        List memory l
    ) internal view returns (bytes4) {
        if (mode & ~uint8(0x83) != 0) return IOloBookBase.BadFlags.selector;
        if (amount == 0) return IOloBookBase.ZeroSize.selector;
        Walk memory w = _walk(s, v, buy, amount, mode & 2 != 0, l);
        if (w.refused) return IOloBookBase.AmountOverflow.selector;
        return _finish(s, p, v, a, buy, amount, mode, maxLeft, w, 0);
    }

    /// `takeThenRest`: the mode bits (WALLET and the probes), a zero amount, the walk in base mode of version `v`'s
    /// orders (the tag its params carry), then, with a remainder, the limit checked as a maker's tick (before it values
    /// anything), and the remainder rested at the limit (a buy's as a bid, a sell's as an ask) in the market's current
    /// version, whichever `v` is, when it is worth minQuote there as stored, else left with the taker; its escrow
    /// settles with the fills. Returns the base and the quote, the amount rested and its order id (0 and 0 with none).
    function _eRest(
        State memory s,
        Plan memory p,
        uint256 v,
        uint256 a,
        bool buy,
        uint256 amount,
        uint256 limit,
        uint8 mode,
        uint32 pos,
        List memory l
    ) internal view returns (bytes4 err) {
        if (mode & ~uint8(0x71) != 0) return IOloBookBase.BadFlags.selector;
        if (amount == 0) return IOloBookBase.ZeroSize.selector;
        Walk memory w = _walk(s, v, buy, amount, false, l);
        uint256 rest = amount - w.filled;
        if (rest != 0 && !_makerTick(limit)) return IOloBookBase.TickOutOfRange.selector;
        (uint256 q, uint256 units) = _units(rest);
        uint256 vNow = s.cur[s.vm[v]];
        uint256 escrow;
        uint256 rested;
        uint256 restId;
        if (_worth(s.vm[v], limit, units * 10 ** q)) {
            uint256 landed;
            (err, landed, escrow) = _mPlace(s, vNow, a, buy, limit, rest, pos, mode & 0x70);
            if (err != 0) return err;
            rested = units * 10 ** q;
            restId = _orderIdAt(s, vNow, landed);
            p.note |= 1 << NOTE_RESTED;
            if (vNow != v && w.count != 0) p.note |= 1 << NOTE_REST_CROSS;
        } else if (rest != 0) {
            p.note |= 1 << NOTE_BELOW_MIN;
        }
        err = _finish(s, p, v, a, buy, amount, mode, 0, w, escrow);
        p.nRet = 4;
        p.ret2 = rested;
        p.ret3 = restId;
    }

    // ------------------------------------------------------------------ generators

    function _tickGen(uint256 mi, uint256 r) internal view returns (uint256) {
        uint256 ctr = (r & 3 == 0 && mFar[mi] != 0) ? mFar[mi] : mCenter[mi];
        return ctr + S * ((r >> 2) % 25) - 12 * S;
    }

    /// A maker's tick: mostly on the spacing near the market's center; now and then one past it (off the spacing
    /// below 6 figures) or 0 (off the grid).
    function _makerTickGen(uint256 mi, uint256 r) internal view returns (uint256) {
        uint256 k = (r >> 16) % 32;
        if (k == 0) return 0;
        uint256 t = _tickGen(mi, r);
        return k == 1 ? t + 1 : t;
    }

    /// An order's amount: a mantissa below 10^4 times a power of ten, by market: 1 .. ~1e18 base wei at P = 1 (q 0 to
    /// 9), 1e8 .. ~1e22 wei of ETH (q 0 to 13), 1 .. ~1e14 sat (q 0 to 5); now and then 0.
    function _amountGen(uint256 mi, uint256 r) internal pure returns (uint256) {
        if ((r >> 40) % 64 == 0) return 0;
        uint256 m = 1 + r % 9_999;
        uint256 e = r >> 16;
        if (mi == 0) return m * 10 ** (e % 15);
        if (mi == 1) return m * 10 ** (8 + e % 11);
        return m * 10 ** (e % 11);
    }

    /// A take's base amount: an order's or up to three times it, or 2^100 (whatever the list holds).
    function _takeAmountGen(uint256 mi, uint256 r) internal pure returns (uint256) {
        if (r % 4 == 0) return 1 << 100;
        return _amountGen(mi, r >> 2) * (1 + (r >> 60) % 3);
    }

    /// A quote-mode amount in quote wei, sized to the market's orders' worth, or 1e24 (whatever the list affords).
    function _quoteAmountGen(uint256 mi, uint256 r) internal pure returns (uint256) {
        if (r % 5 == 0) return 1e24;
        uint256 m = 1 + (r >> 4) % 9_999;
        uint256 e = r >> 20;
        if (mi == 1) return m * 10 ** (e % 11);
        return m * 10 ** (e % 15);
    }

    function _settleGen(uint256 r) internal pure returns (uint8) {
        return uint8([0, 2, 4, 6][r % 4]);
    }

    /// A live position `a` owns in version `v` (with fills when `filled`), from a random start; now and then any
    /// position or one never written.
    function _owned(State memory s, uint256 v, uint256 a, uint256 r, bool filled) internal view returns (uint32) {
        if (r % 8 == 0) return (r >> 3) % 2 == 0 ? uint32((r >> 8) % SCAN) : UNUSED;
        for (uint256 k; k < SCAN; ++k) {
            uint256 p = ((r >> 8) + k) % SCAN;
            uint256 w = s.word[v][p];
            if (_live(w) && _ownerOf(w) == who[a] && (!filled || (w >> 63) & U30 != 0)) return uint32(p);
        }
        return uint32((r >> 8) % SCAN);
    }

    /// A position for a take's entry in version `v`: mostly an order on the side the take consumes, with open units.
    function _pickLive(State memory s, uint256 v, bool buy, uint256 r) internal pure returns (uint32) {
        if (r % 8 == 0) return (r >> 3) % 4 == 0 ? UNUSED : uint32((r >> 8) % SCAN);
        for (uint256 k; k < SCAN; ++k) {
            uint256 p = ((r >> 8) + k) % SCAN;
            uint256 w = s.word[v][p];
            if ((w >> 33) & U30 != 0 && ((w >> 93) & 1 == 1) != buy) return uint32(p);
        }
        return uint32((r >> 8) % SCAN);
    }

    /// A take list of up to 8 pool entries in one segment or two (or none), each bounded by the order's tick, the far
    /// end of the grid, a tick either side of the order's (worse: skipped; better: fills at its own), or a random one.
    function _listGen(State memory s, uint256 v, bool buy, uint256 r) internal view returns (List memory l) {
        uint256 mi = s.vm[v];
        l.n = r % 9;
        uint256 cut = l.n != 0 && (r >> 4) % 3 == 0 ? (r >> 8) % l.n : l.n;
        bytes memory e1;
        bytes memory e2;
        for (uint256 i; i < l.n; ++i) {
            uint256 ri = uint256(keccak256(abi.encode(r, i)));
            uint32 p = _pickLive(s, v, buy, ri);
            uint256 own = _wordAt(s, v, p) & TICK_M;
            if (own == 0) own = mCenter[mi];
            uint256 k = (ri >> 40) % 8;
            uint256 b = k < 3
                ? own
                : k < 5 ? (buy ? TOP_TICK : 1) : k == 5 ? own - 1 : k == 6 ? own + 1 : _tickGen(mi, ri >> 48);
            l.pos[i] = p;
            l.bound[i] = b;
            if (i < cut) e1 = bytes.concat(e1, OloOps.poolEntry(p, b));
            else e2 = bytes.concat(e2, OloOps.poolEntry(p, b));
        }
        if (e1.length != 0) l.data = OloOps.poolList(e1);
        if (e2.length != 0) l.data = bytes.concat(l.data, OloOps.poolList(e2));
    }

    /// A base amount near what the list's entries hold open on the side it takes (each counted once per entry): a
    /// little more, so a little is left (below a unit, below minQuote, or for fill-or-kill's tolerance), or a little
    /// less.
    function _nearOpen(State memory s, uint256 v, bool buy, List memory l, uint256 r)
        internal
        pure
        returns (uint256 open)
    {
        for (uint256 i; i < l.n; ++i) {
            uint256 w = _wordAt(s, v, l.pos[i]);
            if (((w >> 93) & 1 == 1) != buy) open += ((w >> 33) & U30) * 10 ** ((w >> 26) & 0x7f);
        }
        uint256 d = (r >> 1) % 10 ** ((r >> 64) % 14);
        return r % 2 == 0 || open <= d ? open + d : open - d;
    }

    // ------------------------------------------------------------------ the steps

    function _planPlace(State memory t, Plan memory p, uint256 r) internal view {
        uint256 mi = r % NM;
        uint256 a = (r >> 2) % NA;
        bool bid = (r >> 4) & 1 == 1;
        uint256 tick = _makerTickGen(mi, r >> 8);
        uint256 amount = _amountGen(mi, r >> 40);
        uint32 pos = uint32((r >> 96) % NPOS);
        uint8 flags = _settleGen(r >> 104) | uint8(((r >> 108) % 16) << 4);
        if ((r >> 112) % 32 == 0) flags |= 1; // a bit that means nothing: BadFlags
        bool sentC = (r >> 120) % 32 == 0; // the current C, not K: UnknownMarket
        MarketWord c = _c(t, t.cur[mi]);
        p.sender = who[a];
        p.data = abi.encodeCall(book.place, (sentC ? c : OloOps.key(c), OloOps.placeW(bid, tick, amount, pos, flags)));
        p.err = _ePlace(t, p, mi, a, bid, tick, amount, pos, flags, sentC);
    }

    /// A live order in any version (with fills when `filled`; in an older version when `older`), from a random start:
    /// its version, position and maker.
    function _anyOrder(State memory s, uint256 r, bool filled, bool older)
        internal
        view
        returns (bool found, uint256 v, uint32 pos, uint256 a)
    {
        uint256 n = s.nv * SCAN;
        for (uint256 k; k < n; ++k) {
            uint256 i = (r + k) % n;
            uint256 w = s.word[i / SCAN][i % SCAN];
            if (!_live(w) || (filled && (w >> 63) & U30 == 0) || (older && _isCur(s, i / SCAN))) continue;
            while (who[a] != _ownerOf(w)) {
                ++a;
            }
            return (true, i / SCAN, uint32(i % SCAN), a);
        }
    }

    /// A cancel, a claim or a modify: mostly of a live order by its maker in its version (with fills, for a claim),
    /// else of a random actor's own order in a random version of a random market, or of any position. The call names
    /// the market by K and the order's version by the tag in its params.
    function _planOrder(State memory t, Plan memory p, uint256 r, uint256 op) internal view {
        uint256 v = _verOf(t, r % NM, r >> 200);
        uint256 a = (r >> 2) % NA;
        uint8 flags = _settleGen(r >> 4);
        if ((r >> 6) % 32 == 0) flags |= 1; // BadFlags
        uint32 pos = _owned(t, v, a, r >> 16, op == OP_CLAIM);
        if ((r >> 12) % 4 != 0) {
            (bool found, uint256 v2, uint32 pos2, uint256 a2) = _anyOrder(t, r >> 160, op == OP_CLAIM, false);
            if (found) (v, pos, a) = (v2, pos2, a2);
        }
        uint256 mi = t.vm[v];
        uint256 newTick = _makerTickGen(mi, r >> 96);
        uint256 newAmount = _amountGen(mi, r >> 128);
        if (op == OP_MODIFY && (r >> 11) % 8 == 0) {
            // the same tick and open amount as now: NoChange with no fills to pay, else the fills paid
            uint256 w = _wordAt(t, v, pos);
            newTick = w & TICK_M;
            newAmount = ((w >> 33) & U30) * 10 ** ((w >> 26) & 0x7f);
        }
        MarketWord c = _c(t, v);
        p.sender = who[a];
        if (op == OP_CANCEL) {
            p.data = abi.encodeCall(book.cancel, (OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, flags))));
        } else if (op == OP_CLAIM) {
            p.data = abi.encodeCall(book.claim, (OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, flags))));
        } else {
            p.data = abi.encodeCall(
                book.modify, (OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos, newTick, newAmount, flags)))
            );
        }
        p.err = _eOrder(t, p, op, v, a, pos, newTick, newAmount, flags);
    }

    /// A take in one of a market's versions (its current one half the time): K, and the version's tag in the params.
    function _planTake(State memory t, Plan memory p, uint256 r) internal view {
        uint256 mi = r % NM;
        uint256 v = _verOf(t, mi, r >> 200);
        uint256 a = (r >> 2) % NA;
        bool buy = (r >> 4) & 1 == 1;
        bool quoteMode = (r >> 5) % 3 == 0;
        uint8 mode = uint8((r >> 7) & 1) | (quoteMode ? 0x02 : 0) | ((r >> 8) % 4 == 0 ? 0x80 : 0);
        if ((r >> 10) % 64 == 0) mode |= 0x04; // BadFlags
        List memory l = _listGen(t, v, buy, uint256(keccak256(abi.encode(r, "list"))));
        uint256 amount = quoteMode ? _quoteAmountGen(mi, r >> 16) : _takeAmountGen(mi, r >> 16);
        if (!quoteMode && (r >> 140) % 3 == 0) amount = _nearOpen(t, v, buy, l, r >> 144);
        if ((r >> 80) % 64 == 0) amount = 0; // ZeroSize
        // fill-or-kill's tolerance: strict, or up to about the amount (within its 77 bits)
        uint256 cap = amount < (1 << 77) - 1 ? amount + 1 : 1 << 77;
        uint256 maxLeft = (r >> 86) % 3 == 0 ? 0 : (r >> 88) % ((r >> 84) % 2 == 0 ? cap : 1 + cap / 1e6);
        MarketWord c = _c(t, v);
        p.sender = who[a];
        p.data = abi.encodeCall(
            book.take, (OloOps.key(c), l.data, OloOps.tagW(c, OloOps.takeW(buy, amount, mode, maxLeft)))
        );
        p.err = _eTake(t, p, v, a, buy, amount, mode, maxLeft, l);
    }

    /// A takeThenRest filling one of a market's versions (the tag in its params) and resting in its current one.
    function _planRest(State memory t, Plan memory p, uint256 r) internal view {
        uint256 mi = r % NM;
        uint256 v = _verOf(t, mi, r >> 200);
        uint256 a = (r >> 2) % NA;
        bool buy = (r >> 4) & 1 == 1;
        uint8 mode = uint8((r >> 5) & 1) | uint8(((r >> 6) % 8) << 4);
        if ((r >> 9) % 32 == 0) mode |= 0x80; // fill-or-kill means nothing here: BadFlags
        List memory l = _listGen(t, v, buy, uint256(keccak256(abi.encode(r, "list"))));
        uint256 amount = _takeAmountGen(mi, r >> 16);
        if (amount == 1 << 100) amount = _amountGen(mi, r >> 24) * 3; // a rest of 2^100 is no order
        if ((r >> 140) % 2 == 0) amount = _nearOpen(t, v, buy, l, r >> 144);
        uint256 limit = _makerTickGen(mi, r >> 80);
        if (limit == 0) limit = _tickGen(mi, r >> 80);
        uint32 pos = uint32((r >> 120) % NPOS);
        MarketWord c = _c(t, v);
        p.sender = who[a];
        p.data = abi.encodeCall(
            book.takeThenRest, (OloOps.key(c), l.data, OloOps.tagW(c, OloOps.restW(buy, amount, limit, mode, pos)))
        );
        p.err = _eRest(t, p, v, a, buy, amount, limit, mode, pos, l);
    }

    /// A multicall of 1 to 5 ops over none, one or two header entries (perhaps the same market twice), mostly by the
    /// maker of a live order (half the time an older version's) with its version first in the header; an entry names a
    /// market's current version by K (three times in four) or by its C, an older version by its C (K reaches only the
    /// current one). Each op generated
    /// from the model as the ops before it left it, and the model stops at the first op that fails, as the contract
    /// does.
    function _planMulticall(State memory t, Plan memory p, uint256 r) internal view {
        uint256 a = r % NA;
        uint8 settle = _settleGen(r >> 2);
        if ((r >> 4) % 32 == 0) settle |= 1; // BadFlags
        uint256 nm = (r >> 9) % 3;
        uint256[2] memory vs = [_verOf(t, (r >> 11) % NM, r >> 200), _verOf(t, (r >> 13) % NM, r >> 220)];
        bool found;
        if ((r >> 6) % 4 != 0) {
            uint256 v;
            uint256 owner;
            // half the time an older version's order, if there is one
            (found, v,, owner) = _anyOrder(t, r >> 160, false, (r >> 33) % 2 == 0);
            if (!found) (found, v,, owner) = _anyOrder(t, r >> 160, false, false);
            if (found) (vs[0], a) = (v, owner);
        }
        bool[2] memory byKey;
        bytes memory data = abi.encodePacked(uint8(nm));
        for (uint256 i; i < nm; ++i) {
            byKey[i] = _isCur(t, vs[i]) && (r >> (16 + 2 * i)) % 4 != 0;
            MarketWord c = _c(t, vs[i]);
            data = bytes.concat(data, abi.encodePacked(MarketWord.unwrap(byKey[i] ? OloOps.key(c) : c)));
        }
        bytes4 err = settle & ~uint8(6) != 0 ? IOloBookBase.BadFlags.selector : bytes4(0);
        Ledger memory l;
        uint256 n = 1 + (r >> 24) % 5;
        for (uint256 k; k < n; ++k) {
            uint256 rk = uint256(keccak256(abi.encode(r, k)));
            // the first op, half the time, a CANCEL, CLAIM or MODIFY in the found order's version (an older one's
            // through a header C)
            if (k == 0 && found && nm != 0 && (r >> 32) % 2 == 0) rk = (rk & ~uint256(7)) | 6;
            (bytes memory op, bytes4 opErr) = _mcOp(t, p, l, a, nm, vs, byKey, rk, err == 0);
            data = bytes.concat(data, op);
            if (err == 0) err = opErr;
        }
        if (err == 0) err = _commit(t, p, l, a, settle);
        p.sender = who[a];
        p.data = abi.encodeCall(book.multicall, (settle, data));
        p.err = err;
    }

    /// One multicall op, and (when `apply_`) its effect on the model and the ledger: a market op in the version its
    /// header entry names (a PLACE or a MODIFY under an older version's C is MarketFrozen).
    function _mcOp(
        State memory t,
        Plan memory p,
        Ledger memory l,
        uint256 a,
        uint256 nm,
        uint256[2] memory vs,
        bool[2] memory byKey,
        uint256 r,
        bool apply_
    ) internal view returns (bytes memory op, bytes4 err) {
        // PLACE, CANCEL, CLAIM, MODIFY, DEPOSIT, WITHDRAW; low bits 6 (`_planMulticall`'s lead op): CANCEL (half the
        // time), CLAIM or MODIFY on header entry 0
        bool lead = r & 7 == 6 && nm != 0;
        uint256 kind = lead ? [1, 1, 2, 3][(r >> 120) % 4] : nm == 0 ? 4 + r % 2 : r % 6;
        if (kind >= 4) {
            uint256 k = (r >> 8) % NT;
            uint256 id = (r >> 10) % 32 == 0 ? ((r >> 15) % 2 == 0 ? 0 : tokenCount_ + 1) : tid[k]; // BadOp
            // a deposit of up to ~1e24; a withdrawal of part of the account, or all of it and a wei or two more
            uint256 amt = kind == 4
                ? 1 + (r >> 24) % (10 ** ((r >> 64) % 25))
                : (r >> 20) % 4 == 0 ? t.acct[a][k] + (r >> 24) % 3 : (r >> 24) % (t.acct[a][k] + 1);
            op = abi.encodePacked(uint8(kind + 1), uint32(id), uint128(amt));
            if (!apply_) return (op, 0);
            if (id == 0 || id > tokenCount_) return (op, IOloBookBase.BadOp.selector);
            (bool ok, uint256 i) = _entry(l, k);
            if (!ok) return (op, IOloBookBase.TooManyTokens.selector);
            int256 sa = int256(amt);
            l.credit[i] += kind == 4 ? sa : -sa;
            l.wallet[i] += kind == 4 ? -sa : sa;
            return (op, 0);
        }
        uint8 ci = lead ? 0 : uint8((r >> 3) % nm);
        uint256 v = vs[ci];
        uint256 mi = t.vm[v];
        if (apply_) p.note |= 1 << (byKey[ci] ? NOTE_MC_KEY : NOTE_MC_TAG);
        if (kind == 0) {
            bool bid = (r >> 4) & 1 == 1;
            uint256 tick = _makerTickGen(mi, r >> 8);
            uint256 amount = _amountGen(mi, r >> 40);
            uint32 pos = uint32((r >> 96) % NPOS);
            uint8 side = (bid ? 1 : 0) | uint8(((r >> 104) % 16) << 4);
            if ((r >> 108) % 32 == 0) side |= 2; // BadFlags
            op = abi.encodePacked(uint8(1), ci, uint32(tick), side, uint112(amount), pos);
            if (!apply_) return (op, 0);
            uint256 escrow;
            (err,, escrow) = _mPlace(t, v, a, bid, tick, amount, pos, side & 0xfe);
            if (err != 0) return (op, err);
            return (op, _flow(t, l, a, bid ? QT : mBase[mi], -int256(escrow)));
        }
        uint32 own = _owned(t, v, a, r >> 16, kind == 2);
        if (kind == 1) {
            op = OloOps.cancel(ci, own);
            if (apply_) err = _mCancel(t, p, l, v, a, own);
        } else if (kind == 2) {
            op = OloOps.claim(ci, own);
            if (apply_) (err,) = _mClaim(t, p, l, v, a, own);
        } else {
            uint256 newTick = _makerTickGen(mi, r >> 96);
            uint256 newAmount = _amountGen(mi, r >> 128);
            op = OloOps.modify(ci, own, newTick, newAmount);
            if (apply_) err = _mModify(t, p, l, v, a, own, newTick, newAmount);
        }
        if (apply_ && err == 0 && kind != 3 && !_isCur(t, v)) p.note |= 1 << NOTE_MC_OLD;
    }

    /// The market's next version in the model: `changed` (its current C with a field rewritten) one version on, its
    /// positions empty but the first `warm` ones (USED, as `setMarketFee` warms them), the market's current version.
    function _newVersion(State memory t, Plan memory p, uint256 mi, uint256 changed, uint256 warm) internal pure {
        uint256 v = t.nv++;
        t.vc[v] = changed + (1 << 208); // the version, 208-223
        t.vm[v] = mi;
        t.cur[mi] = v;
        for (uint256 pos; pos < SCAN; ++pos) {
            t.word[v][pos] = pos < warm ? 1 << 94 : 0;
        }
        if (warm != 0) p.note |= 1 << NOTE_WARMED;
    }

    /// A share change: above 10,000 MakerShareTooHigh, at the share the market has NoChange; else the market's next
    /// version, which its new orders rest in, while its orders keep their version's C and share. Once the model
    /// keeps NV versions the call asks for the share the market has (NoChange).
    function _planShare(State memory t, Plan memory p, uint256 r) internal view {
        uint256 mi = r % NM;
        uint256 c = t.vc[t.cur[mi]];
        uint256 has = (c >> 174) & 0x3fff;
        uint256 bps = (r >> 2) % 32 == 0 ? 10_001 : (r >> 8) % 10_001;
        if (t.nv == NV) bps = has;
        p.data = abi.encodeCall(book.setMarketMakerShare, (uint32(c >> 224), uint48(bps)));
        if (bps > 10_000) p.err = IOloBookBase.MakerShareTooHigh.selector;
        else if (bps == has) p.err = IOloBookBase.NoChange.selector;
        else _newVersion(t, p, mi, (c & ~(uint256(0x3fff) << 174)) | (bps << 174), 0);
    }

    /// A fee change of up to 1.5% either way from the market's fee (clamped at 0), now and then past 100%: above 100%
    /// BadMarketConfig, at the fee the market has NoChange, a step past 1% FeeStepTooLarge; else the market's next
    /// version with 0 to 3 positions warmed. Once the model keeps NV versions the call asks for the fee the market has.
    function _planFee(State memory t, Plan memory p, uint256 r) internal view {
        uint256 mi = r % NM;
        uint256 c = t.vc[t.cur[mi]];
        uint256 from = (c >> 188) & 0xfffff;
        uint256 step = (r >> 2) % 4 == 0 ? 10_000 + (r >> 8) % 5_001 : (r >> 8) % 10_001;
        uint256 fee = (r >> 40) & 1 == 0 ? from + step : (step > from ? 0 : from - step);
        if ((r >> 41) % 32 == 0) fee = 1_000_001 + (r >> 48) % 4;
        if (t.nv == NV) fee = from;
        uint256 warm = (r >> 56) % 4;
        p.data = abi.encodeCall(book.setMarketFee, (uint32(c >> 224), uint24(fee), uint64(warm)));
        uint256 moved = fee > from ? fee - from : from - fee;
        if (fee > 1_000_000) p.err = IOloBookBase.BadMarketConfig.selector;
        else if (fee == from) p.err = IOloBookBase.NoChange.selector;
        else if (moved > 10_000) p.err = IOloBookBase.FeeStepTooLarge.selector;
        else _newVersion(t, p, mi, (c & ~(uint256(0xfffff) << 188)) | (fee << 188), warm);
    }

    /// A deposit, a withdrawal (all of the account, a wei more than it, part of it, or all but a little: the accounts
    /// run low, so AUTO pulls and debits fall short), or a withdrawal to another actor's wallet.
    function _planAccount(State memory t, Plan memory p, uint256 r) internal view {
        uint256 a = r % NA;
        uint256 k = (r >> 2) % NT;
        uint256 kind = (r >> 4) % 5;
        uint256 bal = t.acct[a][k];
        p.sender = who[a];
        if (kind == 0) {
            uint256 dep = 1 + (r >> 8) % (10 ** ((r >> 72) % 25));
            if ((r >> 80) % 32 == 0) dep = (r >> 85) % 2 == 0 ? 0 : 1 << 128; // ZeroSize, AmountOverflow
            p.data = abi.encodeCall(book.deposit, (address(tok[k]), dep));
            if (dep == 0) p.err = IOloBookBase.ZeroSize.selector;
            else if (dep > type(uint128).max) p.err = IOloBookBase.AmountOverflow.selector;
            else if ((p.err = _pull(t, a, k, dep)) == 0) p.err = _move(t, a, k, int256(dep));
            return;
        }
        uint256 amt = kind == 1 ? bal : kind == 2 ? bal + 1 : kind == 3 ? (r >> 8) % (bal + 1) : bal - bal / 1000;
        uint256 to = kind == 3 && (r >> 90) % 2 == 0 ? (a + 1) % NA : a;
        p.data = to == a
            ? abi.encodeCall(book.withdraw, (address(tok[k]), amt))
            : abi.encodeCall(book.withdrawTo, (address(tok[k]), amt, who[to]));
        if (amt > bal) {
            p.err = IOloBookBase.InsufficientBalance.selector;
            return;
        }
        t.acct[a][k] = bal - amt;
        _push(t, to, k, amt);
    }

    function _planCollect(State memory t, Plan memory p, uint256 r) internal view {
        uint256 k = r % NT;
        p.sender = who[(r >> 2) % NA];
        p.data = abi.encodeCall(book.collectFees, (address(tok[k])));
        p.nRet = 1;
        p.ret0 = t.pot[k];
        _push(t, FEE_H, k, t.pot[k]);
        t.pot[k] = 0;
    }

    /// Runs the plan against the contract: a success must be expected (and return what the model says), a revert must
    /// be the one expected. Returns whether the model after the step is `t` (a success) rather than `s` as it was.
    function _exec(Plan memory p) internal returns (bool) {
        if (p.sender != address(0)) vm.prank(p.sender);
        (bool ok, bytes memory ret) = address(book).call(p.data);
        if (p.err == 0) {
            if (!ok) assertTrue(ok, string.concat("unexpected revert ", vm.toString(ret)));
            if (p.nRet == 1) assertEq(abi.decode(ret, (uint256)), p.ret0, "the return");
            if (p.nRet == 2) {
                (uint256 r0, uint256 r1) = abi.decode(ret, (uint256, uint256));
                assertEq(r0, p.ret0, "the base amount");
                assertEq(r1, p.ret1, "the quote amount");
            }
            if (p.nRet == 4) {
                (uint256 r0, uint256 r1, uint256 r2, uint256 r3) = abi.decode(ret, (uint256, uint256, uint256, uint256));
                assertEq(r0, p.ret0, "the base amount");
                assertEq(r1, p.ret1, "the quote amount");
                assertEq(r2, p.ret2, "the amount rested");
                assertEq(r3, p.ret3, "the rest's order id");
            }
            return true;
        }
        if (ok) assertFalse(ok, string.concat("expected the revert ", vm.toString(abi.encodePacked(p.err))));
        assertEq(bytes4(ret), p.err, "the revert");
        return false;
    }

    /// One step planned on `t`, a copy of the model `s`; returns whether `t` is the model after it.
    function _step(State memory t, uint256 r) internal returns (bool applied) {
        Plan memory p;
        uint256 kind = r % KINDS;
        r >>= 8;
        if (kind <= 4) {
            _planPlace(t, p, r);
        } else if (kind <= 7) {
            _planOrder(t, p, r, kind - 4);
        } else if (kind <= 11) {
            _planTake(t, p, r);
        } else if (kind <= 13) {
            _planRest(t, p, r);
        } else if (kind <= 15) {
            _planMulticall(t, p, r);
        } else if (kind == 16) {
            _planShare(t, p, r);
        } else if (kind == 17) {
            _planFee(t, p, r);
        } else if (kind <= 19) {
            _planAccount(t, p, r);
        } else {
            _planCollect(t, p, r);
        }
        applied = _exec(p);
        if (p.err == 0) {
            ++okKind[kind];
            for (uint256 b; b < NOTES; ++b) {
                if ((p.note >> b) & 1 == 1) ++seen[b];
            }
        } else {
            ++revKind[kind];
            if (p.err == IOloBookBase.FokNotFilled.selector) ++fokReverts;
            if (p.err == IOloBookBase.SellBelowFee.selector) ++sellBelowFee;
            if (p.err == IOloBookBase.MarketFrozen.selector) ++frozenReverts;
            if (p.err == IOloBookBase.UnknownMarket.selector) ++unknownReverts;
        }
    }

    // ------------------------------------------------------------------ the checks

    /// The contract equals the model: every market's current C, the shares `makerShareOf` reports for K and for each
    /// version's C (the current one's, true, true; an older one's 0, true, false), every pool word of every version,
    /// every account and pot, every wallet (the contract's own balance included); and the contract holds what it owes.
    function _check(State memory s) internal view {
        for (uint256 mi; mi < NM; ++mi) {
            MarketWord c = _c(s, s.cur[mi]);
            assertEq(MarketWord.unwrap(book.configOf(c.marketId())), s.vc[s.cur[mi]], "the market's current C");
            (uint16 bps, bool listed, bool active) = book.makerShareOf(OloOps.key(c));
            assertEq(bps, c.makerBps(), "K: the current share");
            assertTrue(listed && active, "K: listed and current");
        }
        for (uint256 v; v < s.nv; ++v) {
            MarketWord c = _c(s, v);
            (uint16 bps, bool listed, bool active) = book.makerShareOf(c);
            bool now_ = _isCur(s, v);
            assertEq(bps, now_ ? c.makerBps() : 0, "C: the share");
            assertTrue(listed, "C: listed");
            assertEq(active, now_, "C: current");
            for (uint256 p; p < SCAN; ++p) {
                uint256 got = book.orderWord(c, uint32(p));
                if (got != s.word[v][p]) {
                    assertEq(
                        got, s.word[v][p], string.concat("word: version ", vm.toString(v), " pos ", vm.toString(p))
                    );
                }
            }
        }
        for (uint256 k; k < NT; ++k) {
            uint256 pot = book.balanceOf(tid[k], address(0));
            if (pot != s.pot[k]) assertEq(pot, s.pot[k], string.concat("pot ", vm.toString(k)));
            for (uint256 a; a < NA; ++a) {
                uint256 got = book.balanceOf(tid[k], who[a]);
                if (got != s.acct[a][k]) {
                    assertEq(got, s.acct[a][k], string.concat("account ", vm.toString(a), " token ", vm.toString(k)));
                }
            }
            for (uint256 h; h < NH; ++h) {
                uint256 got = tok[k].balanceOf(holder[h]);
                if (got != s.wal[h][k]) {
                    assertEq(got, s.wal[h][k], string.concat("wallet ", vm.toString(h), " token ", vm.toString(k)));
                }
            }
        }
        _solventModel(s);
    }

    /// The contract's balance of each token covers every account, the pot, and what every live order settles to (an
    /// ask's open base and its fills' quote, a bid's fills' base and its open quote, each with the whole floored fee).
    function _solventModel(State memory s) internal view {
        uint256[NT] memory owed;
        for (uint256 k; k < NT; ++k) {
            owed[k] = s.pot[k];
            for (uint256 a; a < NA; ++a) {
                owed[k] += s.acct[a][k];
            }
        }
        for (uint256 v; v < s.nv; ++v) {
            uint256 bT = mBase[s.vm[v]];
            for (uint256 p; p < SCAN; ++p) {
                uint256 w = s.word[v][p];
                if (!_live(w)) continue;
                uint256 tick = w & TICK_M;
                uint256 unit = 10 ** ((w >> 26) & 0x7f);
                uint256 open = ((w >> 33) & U30) * unit;
                uint256 filled = ((w >> 63) & U30) * unit;
                uint256 fee = _feeDown(filled, tick, _fee(s, v));
                if ((w >> 93) & 1 == 1) {
                    owed[bT] += filled;
                    owed[QT] += _qDown(open, tick) + fee;
                } else {
                    owed[bT] += open;
                    owed[QT] += _qDown(filled, tick) + fee;
                }
            }
        }
        for (uint256 k; k < NT; ++k) {
            if (s.wal[BOOK_H][k] < owed[k]) {
                assertGe(
                    s.wal[BOOK_H][k], owed[k], string.concat("the book holds what it owes: token ", vm.toString(k))
                );
            }
        }
    }

    /// Every live order of every version is cancelled by its maker (the model's cancel: K, and the version's tag in
    /// the params), then everyone leaves (OloBase's
    /// `_everyoneLeaves` for the fixture's two tokens, the same here for ETH and BTC): base comes out to the wei
    /// (amounts are base wei, never rounded in flight), the quote token keeps the roundings the model counts.
    function _leave(State memory s, State memory t) internal {
        for (uint256 v; v < s.nv; ++v) {
            for (uint256 pos; pos < SCAN; ++pos) {
                uint256 w = s.word[v][pos];
                if (!_live(w)) continue;
                uint256 a;
                while (who[a] != _ownerOf(w)) {
                    ++a;
                }
                _copyInto(t, s);
                Plan memory p;
                p.sender = who[a];
                p.data = abi.encodeCall(book.cancel, (_key(s, v), OloOps.tagW(_c(s, v), OloOps.posW(uint32(pos), 0))));
                p.err = _eOrder(t, p, OP_CANCEL, v, a, uint32(pos), 0, 0, 0);
                assertEq(p.err, bytes4(0), "every order cancels");
                assertTrue(_exec(p), "the cancel");
                (s, t) = (t, s);
            }
        }
        _check(s);
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        for (uint256 k; k < 2; ++k) {
            for (uint256 a; a < NA; ++a) {
                _push(s, a, k, s.acct[a][k]);
                s.acct[a][k] = 0;
            }
            _push(s, FEE_H, k, s.pot[k]);
            s.pot[k] = 0;
        }
        for (uint256 k = 2; k < NT; ++k) {
            for (uint256 a; a < NA; ++a) {
                vm.prank(who[a]);
                book.withdraw(address(tok[k]), s.acct[a][k]);
                _push(s, a, k, s.acct[a][k]);
                s.acct[a][k] = 0;
            }
            book.collectFees(address(tok[k]));
            _push(s, FEE_H, k, s.pot[k]);
            s.pot[k] = 0;
        }
        _check(s);
        assertEq(baseLeft, 0, "base to the wei");
        assertEq(weth.balanceOf(address(book)), 0, "ETH to the wei");
        assertEq(wbtc.balanceOf(address(book)), 0, "BTC to the wei");
        assertEq(quoteLeft, s.wal[BOOK_H][QT], "the quote token keeps the model's roundings");
    }

    /// `_run` in a call of its own, so its memory is its own: the reach test runs four seeds in one test, and the
    /// memory one seed's checks leave behind (every view call's) would make the next seed's dearer.
    function runSeed(uint256 seed) external {
        _run(seed);
    }

    /// The random walk: STEPS steps, the contract checked against the model after each, then everyone leaves.
    function _run(uint256 seed) internal {
        State memory s = _init();
        State memory t = _init();
        _check(s);
        for (uint256 k; k < STEPS; ++k) {
            _copyInto(t, s);
            if (_step(t, uint256(keccak256(abi.encode(seed, k))))) (s, t) = (t, s);
            _check(s);
        }
        _leave(s, t);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_money_model(uint256 seed) public virtual {
        _run(seed);
    }

    /// The same walk on three fresh listings of the same tokens and centers: a fee of 0 to 100%, a minQuote of 2 wei to
    /// 1 USDC, a random maker share.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_money_model_configs(uint256 seed) public virtual {
        _runConfigs(seed);
    }

    function _runConfigs(uint256 seed) internal {
        uint256[3] memory centers = [T, ETH_1000, BTC_100K];
        uint256[3] memory bIdx = [uint256(0), 2, 3];
        for (uint256 i; i < NM; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, "cfg", i)));
            uint24 fee = uint24([0, 1, 50, 3000, 77_777, 500_000, 999_939, 1_000_000][r % 8]);
            uint96 minQuote = uint96([2, 10, 999, 1e6][(r >> 8) % 4]);
            _listAs(i, tok[bIdx[i]], bIdx[i], fee, minQuote, centers[i], i == 1 ? ETH_2500 : 0);
            _shareOf(i, (r >> 16) % 10_001);
        }
        _run(seed);
    }

    /// Over four seeds every kind of step succeeds (the refusals are logged), share and fee changes included, and the
    /// walks reach what they mean to: buys and sells that fill, fills across a decade boundary, quote-mode fills, q > 0
    /// fills, AUTO's pulls, rests and remainders below minQuote, fill-or-kill passing with something left and refusing,
    /// fee splits, probes; and across versions: takes filling an older version at its fee, settles of an older
    /// version's fills at its fee and share, a takeThenRest filling an older version and resting in the current one,
    /// multicall ops under a header K and under a header C (an older version's CANCEL or CLAIM among them), warmed
    /// positions of a new version, MarketFrozen (a modify, or a header C's PLACE or MODIFY, of an older version) and
    /// UnknownMarket (a place naming C).
    function test_model_reaches_every_operation() public {
        uint256[KINDS] memory ok;
        uint256[KINDS] memory rev;
        uint256[NOTES] memory notes;
        uint256 fok;
        uint256 frozen;
        uint256 unknown;
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            this.runSeed(uint256(keccak256(abi.encode("reach", i))));
            for (uint256 k; k < KINDS; ++k) {
                ok[k] += okKind[k];
                rev[k] += revKind[k];
            }
            for (uint256 b; b < NOTES; ++b) {
                notes[b] += seen[b];
            }
            fok += fokReverts;
            frozen += frozenReverts;
            unknown += unknownReverts;
            vm.revertToState(snap);
        }
        for (uint256 k; k < KINDS; ++k) {
            emit log_named_uint(string.concat("kind ", vm.toString(k), " ok"), ok[k]);
            emit log_named_uint(string.concat("kind ", vm.toString(k), " refused"), rev[k]);
        }
        for (uint256 b; b < NOTES; ++b) {
            emit log_named_uint(string.concat("note ", vm.toString(b)), notes[b]);
        }
        for (uint256 k; k < KINDS; ++k) {
            assertGt(ok[k], 0, string.concat("kind ", vm.toString(k), " succeeds"));
        }
        for (uint256 b; b < NOTES; ++b) {
            assertGt(notes[b], 0, string.concat("note ", vm.toString(b)));
        }
        emit log_named_uint("fill-or-kill refusals", fok);
        assertGt(fok, 0, "fill-or-kill refuses");
        emit log_named_uint("MarketFrozen refusals", frozen);
        assertGt(frozen, 0, "an older version refuses a new order");
        emit log_named_uint("UnknownMarket refusals", unknown);
        assertGt(unknown, 0, "a place naming C refuses");
    }

    // ------------------------------------------------------------------ reentrancy matrix

    ReentrantToken rt;
    MarketWord cr; // base rt, quote `quote`
    MarketWord cq; // base `base`, quote rt (fees accrue in rt)
    address rm; // a maker with rt

    function _rtSetup() internal {
        rt = new ReentrantToken();
        uint8 sf = _sigFigs();
        cr = book.configOf(book.listMarketQuote(address(rt), address(quote), 3000, sf, 1, 0));
        uint32 qid = book.listMarketQuote(address(base), address(rt), 3000, sf, 1, 0);
        // a share below 100%, so the claim below leaves rt in the pot for `collectFees` to push (the bid rests in this
        // version and settles at its share)
        book.setMarketMakerShare(qid, 5000);
        cq = book.configOf(qid);
        rm = who[0];
        rt.mint(rm, 1e30);
        rt.mint(taker, 1e30);
        vm.prank(rm);
        rt.approve(address(book), type(uint256).max);
        vm.prank(taker);
        rt.approve(address(book), type(uint256).max);
        // the bid below escrows 1e9 rt (1e9 base wei at P = 1), leaving 900_000: short of outer 3's and outer 6's
        // AUTO escrows of about 3e6, which then pull from the wallet
        vm.prank(rm);
        book.deposit(address(rt), 1e9 + 900_000);
        vm.prank(taker);
        book.deposit(address(rt), 1e12);
        // resting orders for the outer paths: rm's ask in cr at pos 1 (part filled), rm's bid in cq at pos 1
        vm.startPrank(rm);
        book.place(OloOps.key(cr), OloOps.placeW(false, T, 100, 1, 0));
        book.place(OloOps.key(cq), OloOps.placeW(true, T, 1e9, 1, 0));
        vm.stopPrank();
        vm.startPrank(taker);
        book.take(OloOps.key(cr), OloOps.poolList(OloOps.poolEntry(1, T)), OloOps.tagW(cr, OloOps.takeW(true, 40, 0)));
        book.take(OloOps.key(cq), OloOps.poolList(OloOps.poolEntry(1, T)), OloOps.tagW(cq, OloOps.takeW(false, 4e8, 0)));
        vm.stopPrank();
    }

    function _inner(uint256 k) internal view returns (bytes memory) {
        if (k == 0) return abi.encodeCall(book.place, (OloOps.key(cr), OloOps.placeW(false, T, 1, 9, 0)));
        if (k == 1) return abi.encodeCall(book.cancel, (OloOps.key(cr), OloOps.tagW(cr, OloOps.posW(1, 0))));
        if (k == 2) return abi.encodeCall(book.cancel, (OloOps.key(cr), OloOps.tagW(cr, OloOps.posW(1, 4))));
        if (k == 3) return abi.encodeCall(book.claim, (OloOps.key(cr), OloOps.tagW(cr, OloOps.posW(1, 0))));
        if (k == 4) return abi.encodeCall(book.claim, (OloOps.key(cr), OloOps.tagW(cr, OloOps.posW(1, 4))));
        if (k == 5) {
            return abi.encodeCall(book.modify, (OloOps.key(cr), OloOps.tagW(cr, OloOps.modifyW(1, T + S, 5, 0))));
        }
        if (k == 6) {
            return abi.encodeCall(
                book.take,
                (OloOps.key(cr), OloOps.poolList(OloOps.poolEntry(1, T)), OloOps.tagW(cr, OloOps.takeW(true, 1, 0)))
            );
        }
        if (k == 7) {
            return abi.encodeCall(
                book.takeThenRest,
                (
                    OloOps.key(cr),
                    OloOps.poolList(OloOps.poolEntry(1, T)),
                    OloOps.tagW(cr, OloOps.restW(true, 1, T, 0, 5))
                )
            );
        }
        if (k == 8) {
            return OloOps.batchCalldata(book.manageBatchSubs.selector, cr, OloOps.maskW(OloOps.CLAIM, 0, 0, 0));
        }
        if (k == 9) {
            return abi.encodeCall(book.multicall, (0, bytes.concat(OloOps.header(cr), OloOps.deposit(quoteId, 1))));
        }
        if (k == 10) return abi.encodeCall(book.deposit, (address(quote), 1));
        if (k == 11) return abi.encodeCall(book.withdraw, (address(quote), 0));
        if (k == 12) return abi.encodeCall(book.collectFees, (address(quote)));
        if (k == 13) return abi.encodeCall(book.warmPool, (1, 0, 1));
        if (k == 14) return abi.encodeCall(book.listMarketQuote, (address(rt), address(base), 3000, _sigFigs(), 1, 0));
        // a flash, by the token contract (it has code to call back): its first check is the lock
        return abi.encodeCall(book.flash, (address(quote), 1, ""));
    }

    function _outer(uint256 o) internal {
        if (o == 0) {
            vm.prank(rm);
            book.deposit(address(rt), 5);
        } else if (o == 1) {
            vm.prank(rm);
            book.withdraw(address(rt), 5);
        } else if (o == 2) {
            vm.prank(rm);
            book.place(OloOps.key(cr), OloOps.placeW(false, T, 3, 2, 0x02));
        } else if (o == 3) {
            vm.prank(rm);
            book.place(OloOps.key(cr), OloOps.placeW(false, T, 3e6, 2, 0x04));
        } else if (o == 4) {
            vm.prank(rm);
            book.cancel(OloOps.key(cr), OloOps.tagW(cr, OloOps.posW(1, 0x02)));
        } else if (o == 5) {
            vm.prank(rm);
            book.claim(OloOps.key(cq), OloOps.tagW(cq, OloOps.posW(1, 0x02)));
        } else if (o == 6) {
            vm.prank(rm);
            book.modify(OloOps.key(cr), OloOps.tagW(cr, OloOps.modifyW(1, T, 3e6, 0x04)));
        } else if (o == 7) {
            vm.prank(taker);
            book.take(
                OloOps.key(cr), OloOps.poolList(OloOps.poolEntry(1, T)), OloOps.tagW(cr, OloOps.takeW(true, 5, 1))
            );
        } else if (o == 8) {
            vm.prank(taker);
            book.take(
                OloOps.key(cq), OloOps.poolList(OloOps.poolEntry(1, T)), OloOps.tagW(cq, OloOps.takeW(false, 5, 1))
            );
        } else if (o == 9) {
            vm.prank(taker);
            book.takeThenRest(OloOps.key(cr), "", OloOps.tagW(cr, OloOps.restW(false, 5, T + 2 * S, 1, 30)));
        } else if (o == 10) {
            vm.prank(rm);
            _mb(cr, OloOps.ladderW(OloOps.POST, false, 3, 0x02, T, 2, 1, 1));
        } else if (o == 11) {
            vm.prank(rm);
            book.multicall(0x02, bytes.concat(OloOps.header(cr), OloOps.cancel(0, 1)));
        } else if (o == 12) {
            uint256 rid = book.tokenId(address(rt));
            vm.prank(rm);
            book.multicall(0, bytes.concat(abi.encodePacked(uint8(0)), OloOps.deposit(rid, 7)));
        } else {
            vm.prank(rm);
            book.claim(OloOps.key(cq), OloOps.tagW(cq, OloOps.posW(1, 0)));
            book.collectFees(address(rt));
        }
    }

    /// Every path that moves tokens holds the lock, and every writing entry checks it: from inside each outer path's
    /// transfer of the reentrant token, each of 16 entries reverts Locked.
    function test_reentrancy_matrix() public {
        _rtSetup();
        for (uint256 o; o < 14; ++o) {
            for (uint256 k; k < 16; ++k) {
                uint256 snap = vm.snapshotState();
                rt.arm(address(book), _inner(k));
                uint256 a0 = rt.attempts();
                _outer(o);
                assertEq(rt.attempts(), a0 + 1, string.concat("no callback, outer ", vm.toString(o)));
                assertFalse(rt.lastOk(), string.concat("reentered: outer ", vm.toString(o), " inner ", vm.toString(k)));
                assertEq(bytes4(rt.lastRevert()), IOloBookBase.Locked.selector, "not Locked");
                vm.revertToState(snap);
            }
        }
    }
}

/// The model on 5-significant-figure markets: every maker tick a multiple of 10. The subclasses restate the fuzz tests
/// for their run counts: a forge-config line reaches only the contract that declares the function.
contract OloMoneyModel5Test is OloMoneyModelTest {
    function _sigFigs() internal pure override returns (uint8) {
        return 5;
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_money_model(uint256 seed) public override {
        _run(seed);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_money_model_configs(uint256 seed) public override {
        _runConfigs(seed);
    }
}

/// The same at 4 figures (a multiple of 100).
contract OloMoneyModel4Test is OloMoneyModelTest {
    function _sigFigs() internal pure override returns (uint8) {
        return 4;
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_money_model(uint256 seed) public override {
        _run(seed);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_money_model_configs(uint256 seed) public override {
        _runConfigs(seed);
    }
}

/// The same at 3 figures (a multiple of 1000).
contract OloMoneyModel3Test is OloMoneyModelTest {
    function _sigFigs() internal pure override returns (uint8) {
        return 3;
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_money_model(uint256 seed) public override {
        _run(seed);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_money_model_configs(uint256 seed) public override {
        _runConfigs(seed);
    }
}
