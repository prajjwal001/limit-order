// SPDX-License-Identifier: MIT
// Copyright (c) 2026 YOU LI.
pragma solidity ^0.8.8;

import {IOloBookBase} from "./IOloBookBase.sol";
import {IOloBookExt} from "./IOloBookExt.sol";
import {IOwned2Step} from "./IOwned2Step.sol";
import {MarketWord} from "./MarketWord.sol";

/// @title OloBook, the OLO EVM contract: an implementation of the OLO primitive, with no price levels
/// @notice Makers rest orders in pool positions or in their own batch slots (up to four a slot, bids, asks or both);
/// a taker names the orders to fill in a list, and the OLO EVM contract fills them in that order, each at its own
/// price: a base wei at tick t is worth P(t) quote wei, P one 6-significant-figure grid of 74 decades every market
/// shares (PriceGrid). Amounts are base wei; an order stores units x 10^q, and a take fills any amount in whole units
/// of the orders it reaches. The contract keeps no best price
/// and no queue: who rests what where is in the events. A take collects the fee whole; a maker's
/// part of it is paid when the maker settles, at the share of the version its order rests in, and the protocol's fee
/// pot takes the rest.
/// @dev A market has one key K for its whole life (its config word C less the tag: the tokens, the spacing, minQuote,
/// whether the market is proprietary and the id) and a run of versions, one per fee or share change
/// (`MarketConfigSet`): C = K | tag, the tag being the maker share, the fee and the version (bits 174-223). Every order
/// and batch slot rests in one version, its slots hashed from that version's C, and fills and settles there at that
/// version's fee and share. Every market entry takes `k`, the market's key. An entry that rests a new order (`place`, a
/// `takeThenRest`'s rest, a batch post, a multicall run under K) reads the market's current C, refuses any word but K
/// (UnknownMarket), and rests the order in the version current when the call runs: `place` cannot name a version, so a
/// caller that must rest in the version it saw (its fee and share) uses a multicall whose header gives that version's
/// C, MarketFrozen when the version is no longer current. An entry that fills or settles orders (`take`, `cancel`,
/// `claim`, a batch cancel or claim) names their version by the tag its params carry in their top 50 bits (206-255, C's
/// bits 174-223; `place` returns an order's id in that shape) and reads no storage for it: a tag no version has finds
/// no order. These check nothing about `k` itself and must be given K: a word with tag bits set is or-ed with the
/// params' tag, which can happen to name another version (a fee moved away and back makes a version whose tag bits
/// contain the first's), so the cost of a wrong word falls on the caller. An entry that rests an order again in place
/// (`modify`, a batch replace or modify) names the version by the tag the same way and reads the registry: `k` or-ed
/// with the tag must be the market's current C exactly. A `modify` or a batch replace that misses is MarketFrozen when
/// the key is the market's and the tag another version's (older or never made), UnknownMarket when the key is no
/// market's. A batch modify checks first that the slot it names holds a live sub-order: NoOrder when it holds none,
/// whatever the word (a key no market has or a tag never made names a slot nobody could post in, and an older slot may
/// be settled in full); an older version's slot with live sub-orders is MarketFrozen. An older version's orders and
/// slots settle there (cancel, claim) and rest again only by a new order under K. In a proprietary market (K's bit 170,
/// `listMarketQuoteProprietary`) an entry that makes or takes asks the market's policy about its caller
/// (IOloMarketPolicy; NotAdmitted when it refuses). `place`, `modify`, `take`, `takeThenRest` and a batch post, replace
/// or modify ask for a word that carries the bit before any other check of the call but the reentrancy lock, so
/// NotAdmitted comes ahead of every error above; a `takeThenRest` asks again, as a maker, when anything rests, and a
/// multicall asks at the first PLACE or MODIFY of each run of its ops in the market, once its header word is found
/// current (a PLACE's tick and size are checked before that). A cancel, a claim, a batch cancel or claim and a
/// multicall's CANCEL and CLAIM never ask. Every entry takes its scalars in one packed word `params`, laid out in the
/// entry's documentation. Each owner has one account of each token, holding up to 2^128 - 1; a market entry moves the
/// caller's accounts of the market's two tokens, and one whose proceeds would put an account past that reverts
/// AmountOverflow, so it is settled through the wallet (WALLET). The fee pot holds up to 2^255 - 1, so a fill's fee is
/// never too large to settle. `flags` in `params` are SettleFlags (WALLET 0x02, AUTO 0x04); `place`'s flags bits 4-7
/// also ask for up to 15 probes: when the named position is busy the next ones are tried in turn and the order lands on
/// the first free one.
interface IOloBook is IOwned2Step, IOloBookExt, IOloBookBase {
    /// @notice The extension the OLO EVM contract forwards its listing, admin and pre-warming entries to
    function ext() external view returns (address);

    /// @notice The native currency a listing pays, in wei; 0 until the owner sets one (`setCurrentListingFee`).
    /// `collectFees(address(0))` pays what the listings paid to the fee recipient.
    function listingFeeCurrent() external view returns (uint80);

    /// @notice Credits the caller's account of a token from the caller's wallet
    /// @param token A token a listing registered
    /// @param amount The amount, 1 to 2^128 - 1 (the most an account holds)
    function deposit(address token, uint256 amount) external;

    /// @notice Pays from the caller's account of a token to the caller's wallet
    /// @param token A token a listing registered
    /// @param amount The amount, at most the account's balance
    function withdraw(address token, uint256 amount) external;

    /// @notice Pays from the caller's account of a token to another wallet
    /// @param token A token a listing registered
    /// @param amount The amount, at most the account's balance
    /// @param to The wallet, not zero and not the contract (BadAddress: a transfer to the contract strands the amount)
    function withdrawTo(address token, uint256 amount, address to) external;

    /// @notice Rests an order in a pool position of the market's current version, or with probes in the first free one
    /// after it. The position must hold no live order; a dead one, anyone's, or a pre-warmed one is cheapest (each
    /// version has its own positions: a fee or share change leaves the new version's cold until warmed).
    /// @param k The market's key K, exactly (UnknownMarket for any other word, an older or current C included, unless
    /// the word's own fields refuse the call first: the tick and the size are checked on the word's spacing and
    /// minQuote before the registry is read, TickOutOfRange and SizeOutOfRange, and a word with the proprietary bit
    /// asks a policy, NotAdmitted)
    /// @param params isBid 0 | tick 1-26 (a maker's tick: at least 3,600,000, decade 4, and on the market's spacing) |
    /// amount 27-138 (base wei; stored rounded down to units x 10^q, the Placed event logs what is stored) | pos
    /// 139-170 | flags 171-178
    /// @return orderId the position the order landed in 0-31 | its version's tag 206-255, zero between: a cancel's or a
    /// claim's params as they are (`cancel(k, orderId | flags << 32)`), a modify's position and tag
    /// @return stored The amount the order holds and escrowed for, base wei (units x 10^q, at most `amount`)
    function place(MarketWord k, uint256 params) external returns (uint256 orderId, uint256 stored);

    /// @notice Cancels the caller's order, in the version it rests in: pays its fills (and the maker's part of their
    /// fee, at that version's share) and refunds its open amount. The position's word is left dead, keeping its owner,
    /// so the next order there, anyone's, rewrites it.
    /// @param k The market's key K (not checked: a word with tag bits finds the version the or of the two tags names)
    /// @param params pos 0-31 | flags 32-39 | the order's version's tag 206-255 (an order id from `place` with its
    /// flags or-ed in); a tag no version has, or none, is NoOrder
    function cancel(MarketWord k, uint256 params) external;

    /// @notice Pays the caller's order's fills (and the maker's part of their fee, at its version's share); the order
    /// keeps resting with its open amount.
    /// @param k The market's key K, as `cancel`'s
    /// @param params As `cancel`
    /// @return proceeds The fills' proceeds (quote for an ask, base for a bid), without the fee share
    function claim(MarketWord k, uint256 params) external returns (uint256 proceeds);

    /// @notice Changes the caller's order in place: pays its fills, then rests the new size at the new tick in the
    /// same position, moving only the net escrow. The order's version must be the market's current one (MarketFrozen
    /// otherwise, and for a tag no version has or none: an older version's order cancels or claims, and a new one
    /// rests by `place`). Keeping the tick and the open amount is NoChange when the order has no fills to pay;
    /// with fills the modify pays them, as a claim does, and the order rests on with the escrow it holds (no escrow
    /// moves, so no rounding of a bid's), so a take that brings an order down to the size its maker is modifying it to
    /// does not revert the maker's call.
    /// @param k The market's key K, as `cancel`'s
    /// @param params pos 0-31 | newTick 32-57 (a maker's tick) | newAmount 58-169 (base wei, stored as its own units
    /// and q) | flags 170-177 | the order's version's tag 206-255
    /// @return stored The amount the order now holds, base wei (units x 10^q, at most `newAmount`)
    function modify(MarketWord k, uint256 params) external returns (uint256 stored);

    /// @notice Fills from the orders a list names, in the list's order, each at its own price: up to `amount` base wei,
    /// or in quote mode as much as `amount` quote wei pays for (a buy) or as much as brings in at most `amount` quote
    /// wei (a sell). The orders are the version's the params' tag names, at its fee: a list names the orders of one
    /// version, and a tag no version has fills nothing (no revert; fill-or-kill reverts FokNotFilled).
    /// @dev The list is a sequence of segments, kind u8 | length u16 | bytes. Kind 0 holds pool entries, position 4 |
    /// tick 4 each (8,191 at most, a longer list takes several segments): the order in the position fills at its own
    /// tick while that is the entry's tick or better for the taker, and is skipped otherwise (repriced or re-placed
    /// worse, or dead, since the list was built), so an entry's tick bounds its price: it is the most a buy pays there
    /// and the least a sell receives. A list builder writes a ladder: the entries from the best price, each entry's
    /// tick the one it saw at the next entry, the last entry's the taker's limit. An order requoted worse, but no worse
    /// than the next, then still fills at its own tick, and an order placed at a dead position (a pool position is
    /// anyone's once its order is gone) fills at no worse than the next order's price. Kind 1 holds batch groups,
    /// each maker 20 | slot 2 | mask 1 | a tick 4 per sub-order the mask names (bits 0-3, in index order): each named
    /// sub-order on the other side from the taker (a slot may hold both) fills at its own tick while that is the entry's
    /// tick or better, as a pool entry. Orders on the taker's own side, or with nothing open, are skipped. Each
    /// order fills whole units of 10^q base wei (its own q), and what is left walks on down the list: in base mode
    /// min(open, floor(remaining / 10^q)) units; in quote mode the most of its open units the budget still affords at
    /// its price (a quote-mode take reads every entry of its list: a later one can always be cheap enough). The quote
    /// is the fills' exact sum rounded once: up for a buy, down for a sell; the fee is on the exact sum, rounded up.
    /// Quote mode never exceeds the amount: a buy pays (quote and fee) at most `amount`, a sell receives (quote less
    /// fee) at most `amount`; where the walk stops short of the amount at an order with units left, less than one
    /// unit's quote with the fee there is left, plus 1 wei (a buy) or 2 wei (a sell) of rounding. A buy's budget is
    /// exact; a sell's bounds the exact quote, so a sell can stop short of a target its rounded proceeds would have
    /// reached exactly (by less than that bound: one unit's quote less the fee, plus 2 wei), and a strict fill-or-kill
    /// (maxLeft 0) on such a target reverts: a quote-mode sell approximates its amount from below, and a sell that must
    /// receive an exact amount is a base-mode take of the base the caller computes. A quote-mode sell's budget A / (1 -
    /// f) grows as the fee nears 100% (A x 10^6 at 100%); one whose whole part passes 2^126 quote wei (a fee of 999,939
    /// ppm or more) reverts AmountOverflow at the first order the walk reaches that is open, on the other side and
    /// within its entry's tick. A version at a fee of 100% settles no taker sell that fills: SellBelowFee at the end
    /// (a quote-mode sell may revert AmountOverflow first), and no bound on what is left of the amount; a take that
    /// fills nothing succeeds or not by fill-or-kill and the other checks. There is no other bound on the whole take: a
    /// caller wanting one (a router's min out or max in) checks the returned amounts.
    /// @param k The market's key K, as `cancel`'s
    /// @param params buyBase 0 | amount 1-112 | mode 113-120 | maxLeft 121-197 | the version's tag 206-255 (as a
    /// cancel's). mode bit 0 (0x01) settles through the
    /// wallet (else the caller's accounts); bit 1 (0x02) is quote mode: `amount` is quote wei (else base wei); bit 7
    /// (0x80) is fill-or-kill: the take reverts FokNotFilled when what is left of the amount, in its unit, is more than
    /// maxLeft (0: all of it must fill). What is left is the base not filled in base mode, and in quote mode the amount
    /// less what a buy pays or a sell receives. maxLeft is 77 bits, at most 2^77 - 1 (about 1.51e23) in the amount's
    /// unit: a caller whose tolerance is larger (1% of 1e27 wei is 1e25) leaves fill-or-kill off and checks the
    /// returned amounts itself. The other mode bits are BadFlags; bits 198-205 are not read
    /// @param list The orders to fill: segments as above; one of 1 or 2 bytes (a segment header cut short) is
    /// BadTakeList, an empty one fills nothing
    /// @return baseAmount The base received (a buy) or paid (a sell)
    /// @return quoteAmount The quote paid with the fee (a buy) or received less it (a sell)
    function take(MarketWord k, bytes calldata list, uint256 params)
        external
        returns (uint256 baseAmount, uint256 quoteAmount);

    /// @notice `take` in base mode, then rests what did not fill, if worth at least the market's minQuote as stored
    /// (its own units and q), at `limitTick` in a pool position, funded the way the take settled: the rest's escrow
    /// (quote for a buy's bid, base for a sell's ask, the token the take pays either way) settles with the fills, one
    /// pull from the wallet or one debit of the account. A remainder worth less than minQuote at the limit is not
    /// rested and stays with the taker (no revert). `limitTick` bounds the rest only: every order the list names is
    /// bounded by its entry's tick, so a caller keeps those within the limit it rests at. The fills are in the version
    /// the params' tag names, at its fee; the rest is in the market's current version, whichever version filled (an
    /// older version's orders fill, but no new order rests there). With the tag left out (bits 206-255 zero) or one no
    /// version has, the list fills nothing and the whole amount rests at `limitTick` in the current version, with no
    /// revert (a list that names no live order behaves the same).
    /// @dev The rest is placed whatever the OLO Book holds: a named order repriced or replaced away, another taker
    /// filling it first, or a better order the list does not name leaves the rest crossing the OLO Book. `limitTick` is
    /// the price the caller is willing to rest at; a market-like order is a `take`. The rest's position, or one of its
    /// probes (mode bits 4-6, at most 7), must be free: all busy reverts the whole call SlotBusy, fills included, so
    /// name a random position in the market's warmed range. The rest is a maker's order, so whenever anything is left
    /// after the fills `limitTick` must be a maker's tick (at least 3,600,000, decade 4, at most 66,599,999, and a
    /// multiple of the market's spacing 10^(6 - sigFigs)): an invalid limit reverts the whole call TickOutOfRange,
    /// fills included, whatever the remainder is worth; a take that fills everything needs no limit. Snap
    /// the limit before the call.
    /// @param k The market's key K, exactly when anything rests (`place`'s rule: UnknownMarket otherwise); the fills
    /// take it as `take` does
    /// @param list The orders to fill, as `take`'s
    /// @param params buyBase 0 | amount 1-112 (base wei) | mode 113-120 | limitTick 121-146 | pos 147-178 | the fills'
    /// version's tag 206-255; mode bit 0 settles through the wallet, bits 4-6 are the rest's probes; quote mode,
    /// fill-or-kill and the other bits are BadFlags; bits 179-205 are not read (the walk reads 121-197 as a take's
    /// maxLeft, which takeThenRest never uses)
    /// @return baseAmount The fills' base received (a buy) or paid (a sell)
    /// @return quoteAmount The fills' quote paid with the fee (a buy) or received less it (a sell); the rest's escrow
    /// apart
    /// @return rested The amount the rest holds, base wei (units x 10^q of what was left); 0 when nothing rested, and
    /// this is the test for it
    /// @return restOrderId The rest's order id, as `place` returns one: the position it landed in 0-31 | its version's
    /// tag 206-255 (a cancel's or a claim's params, flags apart); 0 when nothing rested
    function takeThenRest(MarketWord k, bytes calldata list, uint256 params)
        external
        returns (uint256 baseAmount, uint256 quoteAmount, uint256 rested, uint256 restOrderId);

    /// @notice Posts, replaces, modifies, cancels or claims in one of the caller's batch slots. A slot is two storage
    /// words holding up to four sub-orders, bids, asks or both, each a tick, a q, open units and its side in the main
    /// word and its base (open units as of its last settlement) in the settlement word, every one on chain; a take
    /// names the slot and the sub-orders it fills (skipping the ones on its own side), and writes the main word only.
    /// @dev Every order rests on its own side s_i (params bit 136 + i, 1 a bid), the same in a post, a replace and a
    /// modify. kind 0, post: the slot must hold no live sub-order (SlotBusy); the orders, 1 to 4 (a zero order, tick
    /// and amount 0, leaves its index empty), rest each on its side, escrowed (asks their amount in base, bids their
    /// quote, rounded up). kind 1, replace: every live sub-order is settled (its fills paid on its own side, its open
    /// amount refunded) and the orders rest as a post's, moving only the net escrow of each token; a replace re-prices
    /// every order it rests (a bid's refund rounded down, its new escrow up, at most a wei apart each); a requote that
    /// keeps some sub-orders is a modify with a mask, which leaves the unnamed ones untouched. kind 2, modify: each
    /// sub-order the mask names is settled and rests again as its order gives, on s_i, live or empty (an empty index
    /// takes a new sub-order). So a caller passes each named live sub-order's side (`batchOf`) to keep it there; the
    /// other side turns it: it is settled on its old side (its fills paid, its open amount refunded) and its order
    /// escrowed on the new one, a changed order even at the same tick and amount. The others are untouched. An order
    /// equal to the sub-order's tick, open amount and side reverts NoChange when the sub-order has no fills to pay
    /// (with fills it rests again and they are paid, as a claim pays them, and no escrow moves for it); an empty
    /// index's zero order reverts NoChange whatever its side. An earlier encoding had a slot side S (params bit 3) and
    /// these bits as flips against it, read by a modify against the S stored: an encoder of that rule must not call
    /// this contract, as the deployment decides the rule (bit 3 set is BadBatch, which refuses its bids, but its modify
    /// of bit 3 clear is read as sides here). kind 3, cancel: each live sub-order the mask names is settled and emptied
    /// (NoOrder when none is live). kind 4, claim: every sub-order's fills are paid, and one with nothing open is
    /// emptied. A settle pays the fills' proceeds and the maker's part of their fee at the share of the slot's version,
    /// the pot the rest. A sub-order stores its amount as its own units and q (fewer than 2^30 units), at least one
    /// unit and worth at least the market's minQuote; its tick is a maker's tick (on the grid, on the spacing). A slot
    /// is (version, maker, slot number): a post rests in the market's current version (`k` exactly K, UnknownMarket
    /// otherwise; the params' tag is not read). Every other kind names the slot by the params' tag, which must be the
    /// slot's own version, the one it was posted in: a cancel and a claim settle that version's slot; a replace and a
    /// modify rest orders again, so that version must also be the current one. A replace of an older version's slot, or
    /// one no version has, is MarketFrozen; a modify is MarketFrozen when the slot it names has a live sub-order, and
    /// NoOrder when it has none (found first: an older slot settled in full, a tag no version has, none). After a fee
    /// or share change a maker cancels the older slot by its tag and posts anew under K: a replace naming the current
    /// version finds that version's own slot, empty for a slot posted before the change, rests there as a post would,
    /// and leaves the older slot live and fillable beside it. A post reads the registry before any other check of its
    /// own, so its unknown key is UnknownMarket ahead of BadBatch and BadFlags; every other kind checks its kind and
    /// flags first. In a proprietary market a post, a replace and a modify ask the policy before all of these
    /// (NotAdmitted, ahead of UnknownMarket, MarketFrozen and NoOrder too); a cancel and a claim never ask.
    /// @param k The market's key K
    /// @param params kind 0-3 (0 to 4; 5 to 15 BadBatch, so bit 3, the earlier encoding's slot side S, set by a caller
    /// of that encoding is refused) | slot 4-19 | flags 20-27 | mask 28-31 | four ticks of 26 bits at 32, 58, 84 and
    /// 110 (orders 0-3) | four sides at 136-139 (s_i, order i's side, 1 a bid; read by a post, a replace and a modify,
    /// for each order it rests) | bits 140-205 not read | the slot's version's tag 206-255 (as a cancel's; a post's is
    /// not read)
    /// @param amountWords The four orders' amounts (base wei, 112 bits each), two a word: [0] amount 0 at 0-111 |
    /// amount 1 at 112-223, [1] amount 2 at 0-111 | amount 3 at 112-223 (an order of tick 0 and amount 0 is left out;
    /// a cancel and a claim read neither word, so [0, 0] serves them). A static array: two words in the ABI with no
    /// offset, so a typed encoder (`abi.encodeCall`, an ethers/viem contract call) sends every order, and bytes a
    /// wallet appends after the arguments are not read
    function manageBatchSubs(MarketWord k, uint256 params, uint256[2] calldata amountWords) external;

    /// @notice Runs a packed stream of pool ops for the caller under one lock, settles one net amount per account,
    /// and logs the stream as one Ops event.
    /// @dev `data` is a header, markets u8 | markets x a market word u256, then the ops, each naming its market by an
    /// index into the header. A header word is the market's key K or one version's C. K names the market's current
    /// version for the whole run of ops under it, read when the stream switches to it (a run of cancels alone reads it
    /// too), so it reaches no older version's order: a cancel or a claim of one takes a header word that is its C. A
    /// C names its version: a CANCEL or a CLAIM settles there, and its first PLACE or MODIFY checks it is the current
    /// one (MarketFrozen otherwise). PLACE 0x01: c u8 | tick u32 | side u8 | amount u112 | pos u32 (25 bytes), the
    /// side byte's bit 0 the side (1 a bid), bits 4-7 the probes and bits 1-3 zero (BadFlags otherwise); one that
    /// probes past busy
    /// positions is logged with pos rewritten to the position it landed in. CANCEL 0x02 and CLAIM 0x03: c u8 | pos u32
    /// (6 bytes). MODIFY 0x04: c u8 | pos u32 | newTick u32 | newAmount u112 (24 bytes). DEPOSIT 0x05 and WITHDRAW
    /// 0x06: tokenId u32 | amount u128 (21 bytes).
    /// @param settle How the net amounts settle (SettleFlags)
    /// @param data The header and the ops
    function multicall(uint8 settle, bytes calldata data) external;

    /// @notice The balance of an account: an owner's holds up to 2^128 - 1; owner 0's account of a token is the
    /// protocol's fee pot and holds up to 2^255 - 1
    /// @param id The token's registry id, below 2^32 (UnknownToken otherwise: a larger id would read another owner's
    /// account)
    /// @param owner The account's owner
    function balanceOf(uint256 id, address owner) external view returns (uint256);

    /// @notice The order in a pool position of one version, all zero if none
    /// @param c The version's C (K | tag): K alone names no version and reads zero
    /// @param pos The position
    /// @return tick The order's tick
    /// @return open Its open amount, base wei
    /// @return filled Its filled amount not yet paid, base wei
    /// @return isBid Its side
    /// @return owner Its maker
    function orderOf(MarketWord c, uint32 pos)
        external
        view
        returns (uint256 tick, uint256 open, uint256 filled, bool isBid, address owner);

    /// @notice A market's maker share now (the makers' part of the fee their fills earn, for the orders of its current
    /// version, paid when they settle), for a market word: K or the current C reads the current share, listed and
    /// active; any other tag on a listed market's key (an older version's, or one no version had) reads (0, true,
    /// false), its share bits not echoed back (an older version's share is in its own C); a key no market has reads
    /// (0, false, false)
    /// @param c A market word: K, or a C
    /// @return makerBps The current share, in bps (0 unless `active`)
    /// @return listed Whether `c`'s key is a listed market's
    /// @return active Whether `c` is K or the current C: the version new orders rest in
    function makerShareOf(MarketWord c) external view returns (uint16 makerBps, bool listed, bool active);

    /// @notice What a listing of two tokens meets and gets now (`listMarketQuote`): the least fee it may carry
    /// (FeeTooLow below it) and the maker share its market starts with, each the pair's own when the owner set one,
    /// else the global one
    /// @param tokenA One token
    /// @param tokenB The other, in either order (either may be the base)
    /// @return floorPpm The least fee a listing of the pair may carry now, in ppm
    /// @return globalFloorPpm The global floor, in ppm (0: none): the constructor's until the owner moves it
    /// @return floorSet Whether the pair has a floor of its own (`setPairFeeFloor`; above or below the global floor,
    /// 0 included)
    /// @return makerBps The maker share a listing of the pair gives its market now, in bps
    /// @return globalBps The global maker share, in bps (0 as deployed)
    /// @return shareSet Whether the pair has a maker share of its own (`setPairMakerShare`; above or below the global
    /// share, 0 included)
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
        );

    /// @notice A pool position's raw word: tick 0-25 | q 26-32 | open 33-62 | filled 63-92 (units of 10^q base wei) |
    /// isBid 93 | USED 94 | owner 96-255
    /// @param c The version's C (K alone reads zero)
    /// @param pos The position
    function orderWord(MarketWord c, uint32 pos) external view returns (uint256);

    /// @notice One of a maker's batch slots: its main word, bit 0 zero | USED 1 | four sub-orders of 61 bits at 2, 63,
    /// 124 and 185, each tick 0-25 | q 26-30 | open 31-60 (units of 10^q base wei; all zero: empty) | side D_i at
    /// 246 + i (sub-order i's side, 1 a bid; 0 while it is empty), and its settlement word, base i at 30 x i |
    /// USED 255 (a live sub-order i's fills are base i - open i; an empty one's base is left over and counts for
    /// nothing); free for a post when every sub-order is empty
    /// @param c The slot's version's C (K alone reads zero)
    /// @param maker The maker
    /// @param slot The slot
    /// @return word The main word
    /// @return set The settlement word
    function batchOf(MarketWord c, address maker, uint16 slot) external view returns (uint256 word, uint256 set);

    /// @notice A market's current config word C = K | tag: its key K (C less bits 174-223) is the word every market
    /// entry takes, and its tag is the version new orders rest in. The views (`orderOf`, `orderWord`, `batchOf`,
    /// `makerShareOf`) take a version's C, and a params word carries its tag. Zero for an id never listed
    /// @param marketId The market
    function configOf(uint32 marketId) external view returns (MarketWord);

    /// @notice The id of the market listed with the parameters `params` packs; 0 when none was. `params` is a listing
    /// word: the parameters `listMarketQuote` or `listMarketQuoteProprietary` took, packed as in C (MarketWord): the
    /// base id at bits 0-31 and the quote id at 32-63 (`tokenId`), the spacing 10^(6 - sigFigs) at 64-73, minQuote at
    /// 74-169, the proprietary bit 170 for a proprietary listing, the fee at 188-207, every other bit 0 below bit 224
    /// (bits 224-255 are not read). OloListings packs it from the listing's arguments. The parameters are the
    /// listing's: a market whose fee was changed since is found by the fee it was listed at, not the one it moved to.
    /// A market's C with its maker share (bits 174-187) and version (208-223) cleared finds it only while its fee is
    /// the one it was listed at. Read the market's current word with `configOf`
    /// @param params The listing word
    function marketIdGivenListingWord(MarketWord params) external view returns (uint32);
}
