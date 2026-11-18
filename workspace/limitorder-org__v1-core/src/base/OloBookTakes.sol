// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {OloBookBatches} from "./OloBookBatches.sol";
import {OloMath} from "../libraries/OloMath.sol";
import {PriceGrid} from "../libraries/PriceGrid.sol";
import {MarketLib} from "../types/Market.sol";
import {MarketWord} from "../interfaces/MarketWord.sol";
import {
    AMOUNT_FIELD,
    BATCH_SIDES,
    BATCH_SUB_BASE,
    BATCH_SUBS,
    OloSlots,
    POOL_BID,
    POOL_FILLED,
    POOL_OPEN,
    POOL_Q,
    POOL_Q_MASK,
    SUB_BITS,
    SUB_MASK,
    SUB_OPEN,
    SUB_Q,
    SUB_Q_MASK,
    TICK_FIELD,
    UNITS_MASK
} from "../OloTypes.sol";

using MarketLib for MarketWord;

/// @title OloBookTakes
/// @notice A take: its state (`Walk`), the walk of the list's segments, the position segment's loop, the exact quote's
/// sum, the quote-mode budget, the one rounding at the end, and the Take event built from the fills as they happen;
/// the two segment loops side by side (`_fillList` over pool words, `_fillBatches` over batch slots). The taker's
/// settlement is OloBookAssets'.
///
/// The money of a take, hard parts first.
///
/// 1. The exact quote. Every fill is x whole units of 10^q base wei at its order's own tick, worth x x 10^q x mantissa
///    x 10^(d - 43) quote wei (PriceGrid). The walk keeps the exact sum of its fills as one integer `sum` aligned to
///    the lowest decade `low` it has met: the quote is Q = sum x 10^(low - 43), a fraction when low < 43. A fill in
///    the sum's decade adds amount x mantissa; one in a higher decade adds that times 10^(d - low); one in a lower
///    decade first scales the sum up by 10^(low - d) (`_accrue`). Nothing is rounded until the walk ends.
///
/// 2. The one rounding (`_finishTake`). A buy pays ceil(Q), a sell receives floor(Q); the fee is ceil(Q x feePpm /
///    10^6) either way. So the OLO EVM contract never pays out a fraction it did not take in, and a take costs at most
///    one wei of rounding on the quote and one on the fee, however many orders it filled.
///
/// 3. The sum's bounds. The adds in the sum's decade are amount x mantissa, unchecked, and total below 2^159: a base
///    mode take fills at most its amount, below 2^112, so they total below 2^132; a quote-mode take has no base cap,
///    but it fills at most the open amounts of the distinct orders its list names, each below 2^114 (2^30 units of up
///    to 10^25 wei), and a list names fewer than 2^25 (its calldata, at 4 gas a byte, fits in no block otherwise), so
///    below 2^139 base wei and adds below 2^159. `_accrue` (and `_affordable` before it scales) holds the sum below
///    SUM_LIMIT = 2^235 after every add in another decade, reverting AmountOverflow past it, so the sum never reaches
///    2^236 and sum x feePpm stays below 2^256 (feePpm at most 10^6 < 2^20). The sum is the quote at its alignment, S =
///    Q x 10^(43 - low), so the limit is on the quote: a take reverts AmountOverflow only when Q x 10^(43 - low)
///    reaches 2^235 at the lowest decade low it has reached (in quote mode a lower decade counts once the walk reaches
///    an order there, before it is priced). Makers rest at decade 4 or above (PriceGrid.MIN_MAKER_TICK) and fills are
///    at makers' ticks, so low >= 4 and a take worth less than 2^235 / 10^39, about 5.52e31 quote wei, never reverts
///    so. Above it a listed order its maker repriced down to decade 4 can revert the caller's take: a denial of that
///    take, never of funds (a known issue, accepted).
///
/// 4. Quote mode (TAKE_QUOTE): the amount A is quote wei, and the walk fills, order by order, the most whole units the
///    budget still affords at each order's price. With f = feePpm / 10^6 the budget is a bound Q <= Q* on the exact
///    quote, Q* = N / Y (`_quoteBudget`):
///      a buy pays g(Q) = ceil(Q) + ceil(Q x f), which grows with Q, so the most it may fill is the largest Q with
///      g(Q) <= A. With n1 = floor(A / (1 + f)): any Q <= n1 passes (n1 (1 + f) <= A, so ceil(n1 f) <= A - n1); a Q
///      in (n1, n1 + 1] has ceil(Q) = n1 + 1 and passes while Q f <= A - n1 - 1; past n1 + 1 none does ((n1 + 1)(1 +
///      f) > A). So Q* = max(n1, (A - n1 - 1) / f), and Q* = A when f is 0: exact, nothing held back.
///      a sell receives floor(Q) - ceil(Q x f) <= Q x (1 - f), so Q* = A / (1 - f) keeps it within A. (What a sell
///      receives does not grow monotonically with Q, by a wei here and there, so the bound is on the exact value; it
///      is sufficient, not tight: a unit whose rounded proceeds would reach A exactly can put Q past Q*, and the walk
///      stops short of it, within the bound below, less than c x (1 - f) + 2.) At a fee of 100% a sell receives
///      nothing whatever it fills, and any fill reverts it SellBelowFee at the end; its budget is A x 10^6, as at
///      1 ppm below (Y = 1).
///    Q* is exact, a fraction, and a sell's grows as the fee nears 100%, to A x 10^6 (below 2^132). The walk refuses a
///    budget whose whole part floor(Q*) passes 2^126: AmountOverflow (`_quoteCap`), at the first order the walk reaches
///    that is open, on the other side and within its entry's tick, before it prices a unit there, so a list it could
///    not fill reverts too. Only a fee of 999,939 ppm or more reaches it (A below 2^112), and at or below 2^126 every
///    cap fits 256 bits.
///    In the sum's terms Q* is a cap on `sum` at its alignment: sum <= cap(low) = floor(N x 10^(43 - low) / Y)
///    (`_quoteCap`), exact integers. Per order, x = min(open, floor((cap - sum) / (a unit's quote in the sum's
///    terms))): the most units the cap still holds. A lower decade re-aligns the cap too, and cap(d) >= cap(low) x
///    10^(low - d) (a floor of a larger multiple), so the sum, scaled with it, stays within it. Where the walk stops
///    short at an order with units left, one more unit c there would have passed the bound, so what is left of A is
///    less than c x (1 + f) + 1 for a buy (g(Q + c) >= A + 1 and g(Q + c) < (Q + c)(1 + f) + 2) and c x (1 - f) + 2 for
///    a sell below a fee of 100% (the two roundings down; at 100% a sell that fills reverts). The walk does not stop
///    early in quote mode: a later entry can always be a unit cheap enough to fill, so it reads every entry of its
///    list; list what is needed and a few spares.
///    The loops tell quote mode by `remaining` alone: it starts at 2^256 - 1 there (no base cap), which no base mode
///    amount (below 2^112) reaches and no quote-mode take fills down to (note 3), so remaining > 2^112 - 1 is quote
///    mode. A flag of its own would take a stack slot the loops do not have, and cost every base-mode fill about 36
///    gas.
abstract contract OloBookTakes is OloBookBatches {
    /// @notice One take: its parameters and the walk's running state. `_newWalk` fills in the parameters; `_openFills`
    /// sizes `fills`; the loops move `remaining`, `sum`, `low`, `cap` and `count` and write their records at `out`;
    /// `_openSegment` and `_closeSegment` keep each segment's header; `_finishTake` rounds the quote, checks
    /// fill-or-kill and trims `fills` to what was written.
    struct Walk {
        uint256 remaining; // base wei the walk may still fill: the amount; in quote mode 2^256 - 1 (no cap; note 4)
        uint256 sum; // the fills' exact quote, aligned to decade `low`: the sum of amount x mantissa x 10^(d - low)
        uint256 low; // the lowest decade a fill has met (the quote is sum x 10^(low - 43)); 0 until the first fill
        // quote mode: the most `sum` may reach at decade `low` (`_quoteCap`); set at the first fill, and again when a
        // fill is in a lower decade
        uint256 cap;
        uint256 count; // the fills so far
        MarketWord c; // the C of the version taken (K and the params' tag): its fee and the account keys read from it
        bool buyBase;
        uint256 amount; // as asked: base wei, or quote wei in quote mode (TAKE_QUOTE)
        uint256 maxLeft; // fill-or-kill's tolerance, in the amount's unit
        uint8 mode;
        bytes fills; // the Take event's fills: per segment that filled, kind 1 | length 3 | its records
        uint256 out; // the fills' write offset: the bytes written so far
        uint256 seg; // the open segment's header offset in the fills
    }

    // A take's params: buyBase 0 | amount 1-112 | mode 113-120 | (take: maxLeft 121-197) | (takeThenRest: limitTick
    // 121-146 | pos 147-178) | the tag of the version whose orders fill 206-255 (MarketLib.withTag, as a cancel's).
    uint256 internal constant TAKE_AMOUNT = 1;

    uint256 internal constant TAKE_MODE = 113;

    uint256 internal constant TAKE_MAX_LEFT = 121;

    /// @dev maxLeft's 77 bits, below the tag.
    uint256 internal constant MAX_LEFT_MASK = 0x1fffffffffffffffffff;

    // A take's mode bits (params bits 113-120). `take` accepts WALLET, QUOTE and FOK; `takeThenRest` WALLET and PROBES.

    /// @dev Settle through the wallet (else the caller's accounts).
    uint8 internal constant TAKE_WALLET = 0x01;

    /// @dev The amount is quote wei: what a buy may pay with the fee, or what a sell may receive less it (else base
    /// wei filled). `take` only.
    uint8 internal constant TAKE_QUOTE = 0x02;

    /// @dev `takeThenRest` mode bits 4-6: the rest's probes (at most 7).
    uint8 internal constant TAKE_PROBES = 0x70;

    /// @dev Fill-or-kill: revert when what is left is more than the params' maxLeft. `take` only.
    uint8 internal constant TAKE_FOK = 0x80;

    uint256 internal constant PPM = 1_000_000;

    /// @notice A take's parameters in memory, from the market's key K and its params word (the version taken is K and
    /// the params' tag, MarketLib.withTag); the walk state starts at zero. In quote mode
    /// `remaining` starts at 2^256 - 1: no base cap, the budget does the limiting (`_affordable`), and the loops tell
    /// the mode by it (note 4).
    function _newWalk(MarketWord k, uint256 params) internal pure returns (Walk memory walk) {
        uint256 amount = (params >> TAKE_AMOUNT) & AMOUNT_FIELD;
        uint8 mode = uint8(params >> TAKE_MODE);
        walk.remaining = mode & TAKE_QUOTE != 0 ? type(uint256).max : amount;
        walk.c = k.withTag(params);
        walk.buyBase = params & 1 != 0;
        walk.amount = amount;
        walk.maxLeft = (params >> TAKE_MAX_LEFT) & MAX_LEFT_MASK;
        walk.mode = mode;
    }

    // A take list's segment: a header (kind u8 | length u16), then its bytes; the kinds. In the Take event's fills a
    // segment's header is kind 1 | length 3: a segment's fills can outgrow its bytes in the list (a position entry
    // of 8 bytes fills a record of 9), so the list's 16-bit length would not hold them.
    uint256 private constant SEG_HEADER = 3;

    uint256 private constant SEG_POSITIONS = 0;

    uint256 private constant SEG_BATCHES = 1;

    /// @dev A segment's header in the fills: kind 1 | length 3.
    uint256 private constant FILL_SEG_HEADER = 4;

    /// @dev A position entry: position 4 | tick 4; its fill record is position 4 | q 1 | units 4.
    uint256 private constant POS_ENTRY = 8;

    uint256 private constant POS_FILL = 9;

    // A fill record as a word (its top bytes): the position at bits 224-255, q at 216-223, the units at 184-215.
    uint256 private constant POS_FILL_POS = 224;

    uint256 private constant POS_FILL_Q = 216;

    uint256 private constant POS_FILL_UNITS = 184;

    /// @dev A batch group's header: maker 20 | slot 2 | mask 1; then a tick of 4 bytes per sub-order the mask names.
    /// Its fills' header is maker 20 | slot 2 | n 1, then n records of index 1 | q 1 | units 4.
    uint256 private constant GROUP_HEADER = 23;

    uint256 private constant GROUP_TICK = 4;

    uint256 private constant GROUP_FILL_HEADER = 23;

    uint256 private constant BATCH_FILL = 6;

    // A group's fills header as a word: the maker at bits 96-255, the slot at 80-95, the count at 72-79. A batch fill
    // record as a word: the index at bits 248-255, q at 240-247, the units at 208-239.
    uint256 private constant GROUP_SLOT_AT = 80;

    uint256 private constant GROUP_COUNT_BYTE = 22;

    uint256 private constant BATCH_FILL_INDEX = 248;

    uint256 private constant BATCH_FILL_Q = 240;

    uint256 private constant BATCH_FILL_UNITS = 208;

    /// @notice A take over a segmented list of pool positions and batch groups: its mode checked (WALLET, QUOTE and FOK
    /// mean something here), the fills, then their settlement.
    function _take(Walk memory walk, bytes calldata list) internal returns (uint256 baseAmount, uint256 quoteAmount) {
        if (walk.mode & ~(TAKE_WALLET | TAKE_QUOTE | TAKE_FOK) != 0) revert BadFlags();
        _takeFills(walk, list);
        return _finishTake(walk, 0);
    }

    /// @notice The fills of a take, its mode checked by the entry: the walk. `_finishTake` settles them; `takeThenRest`
    /// places its rest between the two.
    /// @dev The entries check their own mode bits rather than pass the ones they accept: a parameter here, constant at
    /// each of the two call sites, has via-IR inline the whole walk into both (2.7 kB).
    function _takeFills(Walk memory walk, bytes calldata list) internal {
        if (walk.amount == 0) revert ZeroSize();
        _openFills(walk, list);
        _fillSegments(walk, list);
    }

    // The fills: the Take event's `fills` built in place as the walk goes, so nothing is copied or appended. The loops
    // write each record as one word at `walk.out` (`_put`: the record's bytes at the word's top, the bytes past it
    // covered by the next write or left past the end), and move `out` by the record's size; a segment's and a group's
    // header is written before its records and completed, or dropped, after them.

    /// @notice Sizes the fills for the whole list: a record is at most twice its entry (a position entry of 8 bytes
    /// fills a record of 9, a segment header of 3 one of 4, a group's entry tick of 4 a record of 6), with two words to
    /// spare for the last word written (a write ends at most 32 bytes past what the fills hold).
    function _openFills(Walk memory walk, bytes calldata list) internal pure {
        unchecked {
            // a calldata length is below 2^64 (the ABI decoder checks it)
            walk.fills = new bytes(2 * list.length + 64);
        }
    }

    /// @notice Walks the list's segments (kind u8 | length u16 | bytes): kind 0 is a position list (position 4 | tick 4
    /// each), kind 1 batch groups (maker 20 | slot 2 | mask 1 | a tick 4 per sub-order the mask names). The fills
    /// mirror the list: a header (kind 1 | length 3) before each segment's records, and nothing for a segment that
    /// filled nothing. A segment that runs past the list, or of another kind, is no list (BadTakeList). The walk stops
    /// once no base is left to fill (base mode: the amount is filled); the segments after are not read.
    /// @dev The two loops stay functions of their own: each returns early on an empty segment, and via-IR never
    /// inlines a function with an early return (a Yul `leave`). Inlined here, with this loop's values on the stack
    /// too, they ran out of stack slots, and via-IR moved values to memory, which it then reserves for every entry of
    /// the contract (11 words before the loops went out of line, about 34 gas a call); out of line, neither loop needs
    /// any (OloNoSpill).
    function _fillSegments(Walk memory walk, bytes calldata list) internal {
        uint256 cursor;
        while (cursor < list.length) {
            if (cursor + SEG_HEADER > list.length) revert BadTakeList();
            bytes32 head = _word(list, cursor); // kind 1 | length 2 from its top
            uint256 kind = uint8(bytes1(head));
            uint256 length = uint16(bytes2(head << 8));
            uint256 segEnd = cursor + SEG_HEADER + length;
            if (segEnd > list.length) revert BadTakeList();
            bytes calldata seg = list[cursor + SEG_HEADER:segEnd];
            _openSegment(walk, kind);
            if (kind == SEG_POSITIONS) _fillList(seg, walk);
            else if (kind == SEG_BATCHES) _fillBatches(seg, walk);
            else revert BadTakeList();
            _closeSegment(walk);
            cursor = segEnd;
            if (walk.remaining == 0) break;
        }
    }

    /// @notice Opens a segment's header in the fills: its kind now (written as a word, as the records are: the bytes
    /// after it are covered by the records or left past the end), its fills' length at `_closeSegment`.
    function _openSegment(Walk memory walk, uint256 kind) internal pure {
        uint256 headerAt = walk.out;
        _put(walk.fills, headerAt, bytes32(kind << 248));
        walk.seg = headerAt;
        walk.out = headerAt + FILL_SEG_HEADER;
    }

    /// @notice Closes the open segment's header with its fills' length (3 bytes, big-endian), or drops the header of
    /// a segment that filled nothing.
    function _closeSegment(Walk memory walk) internal pure {
        uint256 headerAt = walk.seg;
        uint256 length = walk.out - headerAt - FILL_SEG_HEADER;
        if (length == 0) {
            walk.out = headerAt;
            return;
        }
        bytes memory fills = walk.fills;
        fills[headerAt + 1] = bytes1(uint8(length >> 16));
        fills[headerAt + 2] = bytes1(uint8(length >> 8));
        fills[headerAt + 3] = bytes1(uint8(length));
    }

    /// @notice Writes `word` into `b` at byte `offset`: its 32 bytes, so `b` must reach `offset + 32` (`_openFills`
    /// keeps a word to spare past every write).
    function _put(bytes memory b, uint256 offset, bytes32 word) internal pure {
        assembly ("memory-safe") {
            mstore(add(add(b, 0x20), offset), word)
        }
    }

    /// @notice The 32 bytes of `b` from byte `start`, read on past `b`'s end when fewer are left (the calldata after
    /// it, or zero past the calldata's end): the caller checks that the bytes it uses are within `b` and reads only
    /// those.
    function _word(bytes calldata b, uint256 start) internal pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := calldataload(add(b.offset, start))
        }
    }

    /// @notice Shortens `b` to `length` bytes, which must be at most its size.
    function _trim(bytes memory b, uint256 length) internal pure {
        assembly ("memory-safe") {
            mstore(b, length)
        }
    }

    /// @dev The take's quote sum is held below 2^235 after every fill in another decade (`_accrue`, `_affordable`).
    uint256 internal constant SUM_LIMIT = 1 << 235;

    /// @notice Adds a fill of `amount` base wei at `tick` to the take's exact quote when its decade is not the sum's
    /// (the loops add a fill in the sum's decade themselves: sum += amount x mantissa). The sum stays aligned to the
    /// lowest decade met so far (`low`): a fill in a higher decade adds amount x mantissa x 10^(d - low), one in a
    /// lower decade first scales the sum up by 10^(low - d). The first fill sets the sum and its decade. Bounds
    /// (OloBookTakes' note 3): amount x mantissa is below 2^132, and here the sum is held below 2^235 (SUM_LIMIT;
    /// AmountOverflow past it).
    function _accrue(uint256 sum, uint256 low, uint256 amount, uint256 tick) internal pure returns (uint256, uint256) {
        unchecked {
            uint256 decade = PriceGrid.decadeOf(tick);
            uint256 v = amount * PriceGrid.mantissaOf(tick); // below 2^132
            if (sum == 0) return (v, decade); // the first fill (a fill adds at least 100_000)
            if (decade > low) {
                uint256 f = OloMath.pow10(decade - low); // at most 10^69: fills are at makers' decades, 4 .. 73
                if (v >= SUM_LIMIT / f) revert AmountOverflow();
                sum += v * f; // below 2^236 + 2^235: v x f < 2^235, the sum below 2^236
            } else {
                uint256 f = OloMath.pow10(low - decade);
                if (sum >= SUM_LIMIT / f) revert AmountOverflow();
                sum = sum * f + v; // below 2^235 + 2^132
                low = decade;
            }
            if (sum >= SUM_LIMIT) revert AmountOverflow();
            return (sum, low);
        }
    }

    /// @notice Quote mode's budget on the exact quote, Q <= Q* = n / y (OloBookTakes' note 4): a sell's A / (1 - f) as
    /// (A x 10^6) / (10^6 - feePpm), and at a fee of 100% (A x 10^6) / 1; a buy's max(n1, (A - n1 - 1) / f) with n1 =
    /// floor(A x 10^6 / (10^6 + feePpm)), as n1 / 1 or ((A - n1 - 1) x 10^6) / feePpm, whichever is larger; A / 1 when
    /// the fee is 0.
    /// Bounds: A below 2^112, feePpm <= 10^6 (a listed market's; a C nobody listed has no live orders to reach here).
    /// n1 < A for a fee above 0 (A / (1 + f) < A), so A - n1 - 1 does not underflow. Every n is below 2^132 and y at
    /// least 1. A buy's n / y is below 2^113: n1 < A; (A - n1 - 1) / f < n1 + 1 (A - n1 < n1 f + 1 + f). A sell's is
    /// up to A x 10^6, below 2^132: `_quoteCap` refuses one past 2^126.
    function _quoteBudget(Walk memory walk) internal pure returns (uint256 n, uint256 y) {
        uint256 amount = walk.amount;
        uint256 ppm = walk.c.feePpm();
        unchecked {
            // A below 2^112, feePpm <= 10^6, n1 < A (the bounds above)
            if (!walk.buyBase) {
                uint256 rest = PPM - ppm; // 1 - f, in ppm
                if (rest == 0) rest = 1; // a sell at 100%: as at 1 ppm below
                return (amount * PPM, rest);
            }
            if (ppm == 0) return (amount, 1);
            uint256 n1 = amount * PPM / (PPM + ppm);
            uint256 n2 = (amount - n1 - 1) * PPM;
            // the larger of n1 / 1 and n2 / feePpm: n1 x feePpm against n2
            return n1 * ppm >= n2 ? (n1, 1) : (n2, ppm);
        }
    }

    /// @notice Quote mode's cap on the sum at decade `decade`: the most `sum`, aligned there, may reach while the
    /// take's quote stays within its budget Q* = n / y (`_quoteBudget`): floor(n x 10^(43 - decade) / y), and at decade
    /// 43 or more floor(n / y / 10^(decade - 43)) (a floor of a floor is the floor of the quotient). Below 43, n x
    /// 10^k / y is computed as (n / y) x 10^k + (n % y) x 10^k / y, exact and without the overflow of n x 10^k.
    /// A budget whose whole part n / y passes 2^126 (a sell's at a fee of 999,939 ppm or more) reverts AmountOverflow
    /// (note 4); `_quoteBudget`'s may, so the bound holds from here on. Bounds: fills are at makers' decades, 4 or
    /// above (PriceGrid.MIN_MAKER_TICK), so k <= 10^39; the cap is below (n / y + 1) x k <= (2^126 + 1) x 10^39 <
    /// 2^256, which bounds both terms' sum; (n % y) x k < 10^6 x 10^39 = 10^45. n / y = 2^126 exactly is reachable by
    /// no A: below 999,939 ppm n / y stays below 2^126, and for y of 1 to 61 no multiple of 10^6 lies in [2^126 y,
    /// 2^126 y + y - 1].
    function _quoteCap(Walk memory walk, uint256 decade) internal pure returns (uint256) {
        (uint256 n, uint256 y) = _quoteBudget(walk);
        unchecked {
            // n / y at most 2^126 past the check, k <= 10^39: below 2^256 (the bounds above)
            uint256 whole = n / y;
            if (whole > 0x40000000000000000000000000000000) revert AmountOverflow(); // past 2^126
            if (decade >= PriceGrid.EXP_OFFSET) return whole / OloMath.pow10(decade - PriceGrid.EXP_OFFSET);
            uint256 k = OloMath.pow10(PriceGrid.EXP_OFFSET - decade);
            return whole * k + (n % y) * k / y;
        }
    }

    /// @notice Quote mode: the most of `x` units (the order's open units: quote mode has no base cap) that the budget
    /// still affords at `tick`, each unit 10^q = `unit` base wei: x limited to floor((cap - sum) / perUnit), where
    /// perUnit is a unit's quote in the sum's terms (unit x mantissa x 10^(d - low)). The walk adds the fill to the sum
    /// as in base mode after this. When the fill is the take's first or in a lower decade than the sum's, the cap is
    /// re-aligned to the order's decade, the sum scaled with it (`_accrue` does the same scaling for the add), and the
    /// new cap written to the walk when anything fills: when room is not 0, since x, the open units, is never 0 here
    /// (both loops skip an order with none); nothing filled leaves the walk as it was. Invariant: sum <= cap
    /// (OloBookTakes' note 4), so cap - sum never underflows. Bounds: unit <= 10^25 < 2^84 and the mantissa below
    /// 2^20, so perUnit < 2^104 at the order's decade; dividing by 10^(d - low) last keeps the higher-decade case free
    /// of the overflow a multiply would risk.
    function _affordable(Walk memory walk, uint256 x, uint256 unit, uint256 tick, uint256 sum, uint256 low)
        internal
        pure
        returns (uint256)
    {
        unchecked {
            // perUnit below 2^104, sum <= cap, the sum below 2^235 before it scales (the bounds above)
            uint256 decade = PriceGrid.decadeOf(tick);
            uint256 perUnit = unit * PriceGrid.mantissaOf(tick); // below 2^104
            uint256 room;
            if (sum != 0 && decade >= low) {
                // the sum's decade or a higher one: the cap as it stands
                room = (walk.cap - sum) / perUnit / OloMath.pow10(decade - low);
            } else {
                // the take's first fill, or a lower decade: the cap at the order's decade, the sum scaled there
                uint256 scaled = 0;
                if (sum != 0) {
                    uint256 f = OloMath.pow10(low - decade);
                    if (sum >= SUM_LIMIT / f) revert AmountOverflow(); // as `_accrue` would
                    scaled = sum * f; // below 2^235
                }
                uint256 cap = _quoteCap(walk, decade);
                room = (cap - scaled) / perUnit; // cap(d) >= cap(low) x 10^(low - d) >= scaled
                if (room != 0) walk.cap = cap;
            }
            return room < x ? room : x;
        }
    }

    /// @notice The end of a take: the quote rounded once, fill-or-kill, the taker's settlement and the Take event. The
    /// fee stays in the contract whole, for the makers' settles to split. `escrow` is a `takeThenRest`'s rest's,
    /// settled with the fills: a buy's rest is a bid escrowing quote and a sell's an ask escrowing base, the token the
    /// take pays either way, so the fills and the rest cost one pull from the wallet, or one debit of the account. The
    /// amounts returned and logged are the fills' alone.
    /// Fill-or-kill (`take` only): what is left of the amount, in its unit, is at most maxLeft, else FokNotFilled.
    /// Base mode: the base not filled. Quote mode: a buy's amount less what it pays (quote and fee), a sell's amount
    /// less what it receives (quote less fee); OloBookTakes' note 4 keeps either within the amount.
    function _finishTake(Walk memory walk, uint256 escrow) internal returns (uint256 baseAmount, uint256 quoteAmount) {
        bool fok = walk.mode & TAKE_FOK != 0;
        if (walk.count == 0) {
            // nothing filled, no event: all of the amount is left; the rest's escrow alone, if there is one, from the
            // account or the wallet
            if (fok && walk.amount > walk.maxLeft) revert FokNotFilled();
            if (escrow != 0) {
                uint256 keys = _acctKeys(walk.c);
                uint256 keyIn = walk.buyBase ? _quoteKey(keys) : _baseKey(keys);
                if (walk.mode & TAKE_WALLET == 0) _debit(keyIn, escrow);
                else _pull(tokenAddr[keyIn], msg.sender, escrow);
            }
            return (0, 0);
        }
        uint8 settlement = walk.mode & TAKE_WALLET;
        uint256 quote;
        uint256 fee;
        unchecked {
            // the quote and the fee in the contract's favour, one rounding each (OloBookTakes' note 2): a buy pays the
            // exact quote rounded up, a sell receives it rounded down, and the fee on the exact quote rounds up either
            // way. No overflow: the sum is below 2^236 (note 3), so sum x feePpm below 2^256; with the sum's decade at
            // 43 or more every fill's decade is too and the quote is whole: in base mode at most an amount below 2^112
            // at a price below 2^120, in quote mode at most the budget Q*, at most 2^126 (note 4: the sum stays within
            // its cap, `_quoteCap`'s check)
            uint256 sum = walk.sum;
            uint256 low = walk.low;
            uint256 ppm = walk.c.feePpm();
            if (low >= PriceGrid.EXP_OFFSET) {
                quote = sum * OloMath.pow10(low - PriceGrid.EXP_OFFSET);
                fee = OloMath.divUp(quote * ppm, PPM);
            } else {
                uint256 div = OloMath.pow10(PriceGrid.EXP_OFFSET - low);
                quote = walk.buyBase ? OloMath.divUp(sum, div) : sum / div;
                fee = OloMath.divUp(sum * ppm, PPM * div);
            }
            // the base filled: what `remaining` started at (`_newWalk`) less what is left of it
            baseAmount = (walk.mode & TAKE_QUOTE != 0 ? type(uint256).max : walk.amount) - walk.remaining;
        }
        if (walk.buyBase) {
            quoteAmount = quote + fee;
        } else {
            if (fee >= quote) revert SellBelowFee(); // a sell that would receive nothing
            unchecked {
                quoteAmount = quote - fee; // fee < quote, checked above
            }
        }
        if (fok) {
            // checked: in quote mode note 4 keeps the quote amount within the amount
            uint256 left = walk.mode & TAKE_QUOTE != 0 ? walk.amount - quoteAmount : walk.remaining;
            if (left > walk.maxLeft) revert FokNotFilled();
        }
        // the escrow joins what the taker pays (no overflow: the escrow is below 2^235, the amounts checked)
        uint256 acctKeys = _acctKeys(walk.c);
        if (walk.buyBase) {
            _settle(settlement, _quoteKey(acctKeys), quoteAmount + escrow, _baseKey(acctKeys), baseAmount);
        } else {
            _settle(settlement, _baseKey(acctKeys), baseAmount + escrow, _quoteKey(acctKeys), quoteAmount);
        }
        // packed: buyBase 0 | the fills' count 8-; the fills trimmed to what the walk wrote
        uint256 packed = (walk.buyBase ? 1 : 0) | (walk.count << 8);
        _trim(walk.fills, walk.out);
        emit Take(uint48(walk.c.marketKey()), msg.sender, packed, baseAmount, quote, fee, walk.fills);
    }

    /// @notice Whether an order at `tick` is worse for the taker than the tick its entry names: an ask above it for a
    /// buy, a bid below it for a sell. The loops skip such an order (repriced worse, or replaced, since the list was
    /// built); one at the entry's tick or better fills at its own.
    function _worse(bool buyBase, uint256 tick, uint256 entryTick) internal pure returns (bool) {
        return buyBase ? tick > entryTick : tick < entryTick;
    }

    /// @notice Walks a position segment. An entry is position 4 | tick 4, the taker's bound for the position (the
    /// tick it saw the order at, or its limit):
    /// whatever order rests in the position fills while it is on the side the take consumes at that tick or better
    /// (an ask at or below it for a buy, a bid at or above it for a sell), at its own tick. So a position repriced or
    /// re-placed at a worse tick, or dead, since the list was built is skipped, and one repriced or re-placed at a
    /// better tick fills there (a `takeThenRest`'s `limitTick` bounds the rest, not entries the taker priced itself).
    /// Each order fills whole units: x = min(open, floor(remaining / 10^q)), and in quote mode no more than the budget
    /// affords (`_affordable`); what is left walks on down the list. Each order is one word, read once and written once
    /// (not at all when x is 0). A fill's record, position 4 | q 1 | units 4, goes into the fills.
    function _fillList(bytes calldata positions, Walk memory walk) internal {
        // whole entries (at most 8,191: the segment's length is 16 bits)
        if (positions.length % POS_ENTRY != 0) revert BadTakeList();
        // nothing to walk (and a return that keeps the loop out of line: `_fillSegments`)
        if (positions.length == 0) return;
        // the walk's running state in locals for the loop, written back after it
        uint256 remaining = walk.remaining;
        uint256 sum = walk.sum;
        uint256 low = walk.low;
        uint256 out = walk.out;
        bytes memory fills = walk.fills;
        MarketWord c = walk.c;
        bool buyBase = walk.buyBase;
        unchecked {
            // no overflow: x <= open, and x <= remaining / unit in base mode so amount <= remaining (in quote mode
            // remaining stays above 2^255, note 4); the cursor stays within the segment and `out` within the fills
            // (`_openFills`); the sum within its bounds (note 3)
            for (uint256 cursor; cursor < positions.length && remaining != 0; cursor += POS_ENTRY) {
                // the entry as a word: position 4 | tick 4 at its top (within the segment: whole entries)
                bytes32 entry = _word(positions, cursor);
                uint32 pos = uint32(bytes4(entry));
                uint256 entryTick = uint32(bytes4(entry << 32));
                uint256 slot = OloSlots.orderSlot(c, pos);
                uint256 word = OloSlots.load(slot);
                // the order's open units, side and tick
                uint256 open = (word >> POOL_OPEN) & UNITS_MASK;
                bool isBid = (word >> POOL_BID) & 1 == 1;
                uint256 tick = word & TICK_FIELD;
                // nothing open (dead, or filled whole), or the taker's own side: skipped
                if (open == 0 || isBid == buyBase) continue;
                if (_worse(buyBase, tick, entryTick)) continue;
                uint256 q = (word >> POOL_Q) & POOL_Q_MASK;
                uint256 unit = OloMath.pow10(q);
                // whole units at the order's own tick: base mode x = min(open, floor(remaining / 10^q)), quote mode
                // the most of the open units the budget affords; the units move from open to filled (the two never
                // carry: PoolWord). (Quote mode first, in its own arm: measured the cheapest shape for base mode.)
                uint256 x;
                if (remaining > AMOUNT_FIELD) {
                    x = _affordable(walk, open, unit, tick, sum, low);
                } else {
                    x = remaining / unit;
                    if (x > open) x = open;
                }
                if (x == 0) continue;
                OloSlots.store(slot, word - (x << POOL_OPEN) + (x << POOL_FILLED));
                uint256 amount = x * unit;
                remaining -= amount;
                // the exact quote: in the sum's decade added here (unchecked: note 3), else `_accrue`
                if (PriceGrid.decadeOf(tick) == low) {
                    sum += amount * PriceGrid.mantissaOf(tick);
                } else {
                    (sum, low) = _accrue(sum, low, amount, tick);
                }
                _put(fills, out, bytes32((uint256(pos) << POS_FILL_POS) | (q << POS_FILL_Q) | (x << POS_FILL_UNITS)));
                out += POS_FILL;
            }
            // the fills' count: a record each, counted from the records (the loop keeps no counter, as the batch loop)
            walk.count += (out - walk.out) / POS_FILL;
        }
        walk.remaining = remaining;
        walk.sum = sum;
        walk.low = low;
        walk.out = out;
    }

    /// @notice `groups`: maker 20 | slot 2 | mask 1 | a tick 4 per sub-order the mask names (bits 0-3, sub-orders 0-3),
    /// per slot. Per group: the slot's main word read once and written back once if anything filled (the settlement
    /// word is not touched). Per named sub-order, in index order: skipped when it has no open units, rests on the
    /// taker's own side (its side D_i: a buy takes asks, a sell bids, as a pool word's side decides) or rests at
    /// a worse tick than the entry's (repriced worse or replaced since the list was built; the entry's tick is the
    /// taker's bound, as a position entry's); otherwise x = min(open, floor(remaining / 10^q)) units, in quote mode no more than the budget
    /// affords (`_affordable`), fill at the sub-order's own tick, taken from its open units. Into the fills, per slot
    /// that filled: a header (maker 20 | slot 2 | n 1) then n records of index 1 | q 1 | units 4. The position
    /// segment's loop, `_fillList`, is the same walk over pool words.
    function _fillBatches(bytes calldata groups, Walk memory walk) internal {
        // nothing to walk (and a return that keeps the loop out of line: `_fillSegments`)
        if (groups.length == 0) return;
        // the walk's running state in locals for the loop, written back after it; C, the side and the fills' count
        // stay in the walk, read or added where they are used (once a group, or once a sub-order), so the loop's
        // values fit the stack
        uint256 remaining = walk.remaining;
        uint256 sum = walk.sum;
        uint256 low = walk.low;
        uint256 out = walk.out;
        bytes memory fills = walk.fills;
        uint256 cursor;
        unchecked {
            // no overflow: x <= open, and in base mode amount <= remaining (in quote mode remaining stays above 2^255,
            // OloBookTakes note 4); the cursor is checked against the segment's end and `out` stays within the fills
            // (`_openFills`); the sum within its bounds (note 3)
            while (cursor < groups.length && remaining != 0) {
                // the group's header as a word (maker 20 | slot 2 | mask 1 at its top), then a tick per sub-order the
                // mask names; a group past the list's end, naming no sub-order, or naming one past 3 is no list
                if (cursor + GROUP_HEADER > groups.length) revert BadTakeList();
                bytes32 header = _word(groups, cursor);
                address maker = address(bytes20(header));
                uint16 slotNo = uint16(bytes2(header << 160));
                uint256 mask = uint8(bytes1(header << 176));
                if (mask == 0 || mask > SUBS_MASK) revert BadTakeList();
                uint256 tickAt = cursor + GROUP_HEADER;
                cursor = tickAt + _bitsSet(mask) * GROUP_TICK;
                if (cursor > groups.length) revert BadTakeList();
                // the group's ticks as one word: a tick of 4 bytes per sub-order the mask names, in mask order from
                // its top (16 bytes at most; the bytes after them are not read)
                bytes32 ticks = _word(groups, tickAt);
                // the slot's main word, read once; a never-written slot reads 0 (no sub-order)
                uint256 slot = OloSlots.batchSlot(walk.c, maker, slotNo);
                uint256 word = OloSlots.load(slot);
                // the group's fills header, maker 20 | slot 2, its count filled in after the records
                uint256 headerAt = out;
                _put(fills, headerAt, bytes32((uint256(uint160(maker)) << 96) | (uint256(slotNo) << GROUP_SLOT_AT)));
                uint256 recordAt = headerAt + GROUP_FILL_HEADER;
                // the four sub-orders in index order, the ones the mask names, while base is wanted
                for (uint256 i; i < BATCH_SUBS && remaining != 0; ++i) {
                    if ((mask >> i) & 1 == 0) continue;
                    // the entry's tick, the taker's bound for sub-order i: the next tick of the group's
                    uint256 entryTick = uint32(bytes4(ticks));
                    ticks <<= 32;
                    uint256 lowBit = BATCH_SUB_BASE + i * SUB_BITS;
                    uint256 sub = (word >> lowBit) & SUB_MASK;
                    uint256 open = sub >> SUB_OPEN;
                    uint256 tick = sub & TICK_FIELD;
                    // nothing open, on the taker's own side (D_i, as a pool word's side is), or a worse tick than the
                    // entry's: skipped
                    if (
                        open == 0 || ((word >> (BATCH_SIDES + i)) & 1 == 1) == walk.buyBase
                            || _worse(walk.buyBase, tick, entryTick)
                    ) continue;
                    uint256 q = (sub >> SUB_Q) & SUB_Q_MASK;
                    uint256 unit = OloMath.pow10(q);
                    // whole units at the sub-order's own tick, as `_fillList` takes them: base mode x = min(open,
                    // floor(remaining / 10^q)), quote mode the most of the open units the budget affords; taken from
                    // its open units (its base keeps the fills for the maker's settle)
                    uint256 x;
                    if (remaining > AMOUNT_FIELD) {
                        x = _affordable(walk, open, unit, tick, sum, low);
                    } else {
                        x = remaining / unit;
                        if (x > open) x = open;
                    }
                    if (x == 0) continue;
                    word -= x << (lowBit + SUB_OPEN);
                    uint256 amount = x * unit;
                    remaining -= amount;
                    // the exact quote: in the sum's decade added here (unchecked: note 3), else `_accrue`
                    if (PriceGrid.decadeOf(tick) == low) {
                        sum += amount * PriceGrid.mantissaOf(tick);
                    } else {
                        (sum, low) = _accrue(sum, low, amount, tick);
                    }
                    // index 1 | q 1 | units 4
                    _put(
                        fills,
                        recordAt,
                        bytes32((i << BATCH_FILL_INDEX) | (q << BATCH_FILL_Q) | (x << BATCH_FILL_UNITS))
                    );
                    recordAt += BATCH_FILL;
                }
                // the group's fills: their count (a record each, counted from the records: the loop keeps no counter)
                // into the header and the walk's count, the write offset past them, and the word written back once;
                // none, the header is dropped (the offset stays)
                uint256 n = (recordAt - headerAt - GROUP_FILL_HEADER) / BATCH_FILL;
                if (n != 0) {
                    fills[headerAt + GROUP_COUNT_BYTE] = bytes1(uint8(n));
                    out = recordAt;
                    walk.count += n;
                    OloSlots.store(slot, word);
                }
            }
        }
        walk.remaining = remaining;
        walk.sum = sum;
        walk.low = low;
        walk.out = out;
    }

    /// @notice The bits set in a 4-bit mask (at most SUBS_MASK, which the caller checks): how many sub-orders a group
    /// names.
    function _bitsSet(uint256 mask) internal pure returns (uint256) {
        unchecked {
            // four bits: at most 4
            return (mask & 1) + ((mask >> 1) & 1) + ((mask >> 2) & 1) + (mask >> 3);
        }
    }
}
