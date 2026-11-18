// SPDX-License-Identifier: MIT
// Copyright (c) 2026 YOU LI.
pragma solidity ^0.8.8;

/// @title OloBook's errors, events and listing state, shared by the OLO EVM contract and its extension
interface IOloBookBase {
    /// @notice Thrown when a call re-enters the contract while a call that moves tokens holds the lock
    error Locked();

    /// @notice Thrown when an entry that rests an order by the market's key (a place, a takeThenRest's rest, a batch
    /// post, a multicall header K) is given a word that is not a listed market's K exactly (tag bits included), when a
    /// word's key is no listed market's, or when a market id has no market. A place checks its tick and size on the
    /// word's own spacing and minQuote before it reads the registry, and a word with the proprietary bit asks a policy
    /// first, so a word that is no market's K may meet TickOutOfRange, SizeOutOfRange or NotAdmitted instead
    error UnknownMarket();

    /// @notice Thrown when listing parameters that are already listed
    error MarketExists();

    /// @notice Thrown when an entry that rests an order in the version a C names (a modify, a batch replace or modify,
    /// a multicall PLACE or MODIFY under a header C) names one that is not the market's current version, the key being
    /// a listed market's: an older version (after `setMarketFee` or `setMarketMakerShare` made a new one), whose orders
    /// still fill, cancel and claim, or a tag no version ever had (forged, a version not made yet, none). A batch
    /// modify naming a slot with no live sub-order is NoOrder instead, checked first, whatever its tag
    error MarketFrozen();

    /// @notice Thrown when a fee or share change would take a market past its last version, 65,535
    error TooManyVersions();

    /// @notice Thrown when a listing's fee is below its floor: its pair's, when the owner set one, else the global one
    /// (`pairDefaultsOf`)
    error FeeTooLow();

    /// @notice Thrown when an owner's call would move a fee by more than 1% of the quote (10,000 ppm), up or down:
    /// `setMarketFee`'s new fee against the market's, `setGlobalFeeFloor`'s floor against the global floor, and
    /// `setPairFeeFloor`'s against the floor a listing of the pair meets now (the pair's own when set, else the global
    /// one; a lift moves it to the global one)
    error FeeStepTooLarge();

    /// @notice Thrown when a maker's tick (a place's, a modify's, a batch order's, a takeThenRest's limit with a
    /// remainder) is below the makers' floor 3,600,000 (decade 4), above 66,599,999, or off the market's spacing
    error TickOutOfRange();

    /// @notice Thrown when an order's amount (as stored, units x 10^q) is zero or worth less than the market's minQuote
    /// at its tick
    error SizeOutOfRange();

    /// @notice Thrown when a take asks for a zero amount, a deposit or a flash for no amount, or a batch post or replace
    /// rests no order
    error ZeroSize();

    /// @notice Thrown when an entry's flags (a place's, a cancel's, claim's or modify's, a batch's, a multicall's), a
    /// take's mode or a multicall PLACE's side byte carry bits that mean nothing
    error BadFlags();

    /// @notice Thrown when a take list is malformed: a segment header cut short (a list of 1 or 2 bytes), a segment of
    /// an unknown kind or running past the list, a position segment whose length is not a whole number of entries, or a
    /// batch group naming no sub-order or one past 3, or running past its segment
    error BadTakeList();

    /// @notice Thrown when a warming range is empty or longer than 512 positions
    error BadWarmRange();

    /// @notice Thrown when a pool position holds a live order and no probe found a free one, or a batch post's slot
    /// holds a live sub-order
    error SlotBusy();

    /// @notice Thrown when a pool position holds no order, or a batch modify's or cancel's slot (a cancel's named
    /// sub-orders) none
    error NoOrder();

    /// @notice Thrown when a modify (a batch modify's named sub-order) keeps both the tick and the open amount of an
    /// order with no fills to pay (a batch sub-order its side too; an empty index's zero order whatever its side), or
    /// when `setMarketFee` or `setMarketMakerShare` names the value the market has (a change makes a version: the same
    /// value would make one for nothing)
    error NoChange();

    /// @notice Thrown when a claim finds no fills to pay
    error NothingToClaim();

    /// @notice Thrown when the caller does not own the order
    error NotOrderOwner();

    /// @notice Thrown when an owner's balance would exceed 2^128 - 1 (a flash's credit included, and a flash of more than
    /// 2^128 - 1), or the fee pot's 2^255 - 1, or a take's exact quote sum, aligned to the lowest decade low it reaches,
    /// 2^235: Q x 10^(43 - low) >= 2^235. Makers rest at decade 4 or above, so a take worth less than about 5.52e31 quote
    /// wei never reverts so. And when a quote-mode sell's budget A / (1 - f) (A x 10^6 at a fee of 100%) passes 2^126
    /// quote wei in its whole part, at the first order the walk reaches that is open, on the other side and within its
    /// entry's tick: a fee of 999,939 ppm or more
    error AmountOverflow();

    /// @notice Thrown when a multicall stream is malformed: an unknown op, a truncated op, a market index past the
    /// header, or a token id no listing registered
    error BadOp();

    /// @notice Thrown when a multicall touches more accounts than its ledger holds
    error TooManyTokens();

    /// @notice Thrown when an account holds less than a debit: a flash's repayment included, an account holding less
    /// than the credit when the callback returns
    error InsufficientBalance();

    /// @notice Thrown when a fill-or-kill take leaves more of its amount than its maxLeft
    error FokNotFilled();

    /// @notice Thrown when a sell's fee is not less than its quote, floor(Q) <= ceil(Q x f): the taker would give base
    /// and receive nothing. At 50 ppm a sell worth under 2 quote wei meets it (a list builder leaves out a dust bid
    /// that would be a sell's only fill); at 50% one of Q = 2.5 does (3 receives 1), at 99% one of 198.99 (199
    /// receives 1), and at 100% every sell that fills
    error SellBelowFee();

    /// @notice Thrown when a pull does not grow the contract's balance by exactly the amount pulled (a fee on transfer
    /// delivers less)
    error FeeOnTransfer();

    /// @notice Thrown when an address that must be set is zero or the OLO EVM contract itself (a withdrawal's
    /// recipient, the fee recipient: a transfer to the OLO EVM contract moves nothing and strands what it was to move),
    /// or when the extension given at construction has no code (a delegatecall to it would succeed with nothing), or a
    /// flash's caller has none (there is nothing to call back)
    error BadAddress();

    /// @notice Thrown when listing parameters are out of range (sigFigs, feePpm), a token has no code, or base is
    /// quote; or when a fee floor or a `setMarketFee` fee is above 1,000,000 ppm, a pair's fee floor or maker share
    /// names one token twice, or a lift of either names a value other than 0 (a maker share lift's value above 10,000
    /// is MakerShareTooHigh, checked before the lift's value and after the pair's two tokens)
    error BadMarketConfig();

    /// @notice Thrown when a listing does not send the listing fee exactly (`listingFeeCurrent` wei)
    error BadListingFee();

    /// @notice Thrown when a maker share is above 10,000 bps
    error MakerShareTooHigh();

    /// @notice Thrown when the token registry is full
    error TokenRegistryFull();

    /// @notice Thrown when a deposit, a withdrawal, a flash or a fee collection names a token no listing registered, or a
    /// balance query an id past the registry's 32 bits (it would read another owner's account)
    error UnknownToken();

    /// @notice Thrown when a batch operation's kind is unknown, or a modify or cancel names no sub-order
    error BadBatch();

    /// @notice Thrown when a proprietary listing's caller is not a lister the owner allows
    error NotProprietaryLister();

    /// @notice Thrown when a proprietary listing's policy is an address without code
    error BadPolicy();

    /// @notice Thrown when a proprietary market's policy does not admit the caller of an entry that makes or takes
    /// there (IOloMarketPolicy)
    error NotAdmitted();

    /// @notice Emitted when an order rests in a pool position (by `place` or the rest of `takeThenRest`)
    /// @param maker The order's owner
    /// @param packed tick 0-25 | isBid 26 | q 27-31 | amount 32-143 (base wei, as stored: units x 10^q) | position
    /// 144-175 | market key 176-223: the version the order rests in 176-191, the market id 192-223 (C's top 48 bits;
    /// the version's fee and share are the C its MarketListed or MarketConfigSet logged). q is the order's unit
    /// exponent (the amount alone does not always name it)
    event Placed(address indexed maker, uint256 packed);

    /// @notice Emitted when an order is modified in place
    /// @param maker The order's owner
    /// @param packed As `Placed`, with the new tick, q and amount as stored, plus the old tick at 224-249
    event Modified(address indexed maker, uint256 packed);

    /// @notice Emitted when an order is cancelled
    /// @param maker The order's owner
    /// @param packed As `Placed` (the order's tick, side and q); the amount is the open amount refunded
    event Cancelled(address indexed maker, uint256 packed);

    /// @notice Emitted when an order's fills are paid (by a claim, or a cancel or modify of a filled order)
    /// @param maker The order's owner
    /// @param packed As `Placed` (the order's tick, side and q); the amount is the filled amount paid, in base wei
    /// @param amount The proceeds, without the maker's part of the fee
    event Claimed(address indexed maker, uint256 packed, uint256 amount);

    /// @notice Emitted once per multicall, with its op stream as it ran
    /// @param maker The caller
    /// @param ops The stream, header included; a PLACE that probed past busy positions shows the position it landed
    /// in
    event Ops(address indexed maker, bytes ops);

    /// @notice Emitted once per take that fills anything
    /// @param marketKey The market and the version taken: the id << 16 | the version (C's top 48 bits)
    /// @param taker The caller
    /// @param packed buyBase (bit 0) | the number of orders filled << 8
    /// @param baseAmount The base the taker received (a buy) or paid (a sell), in base wei
    /// @param quote The quote of the fills, before the fee
    /// @param fee The taker's fee, held by the contract until the makers settle
    /// @param fills Segments mirroring the take's list, each kind 1 | length 3 | records: a position segment's
    /// records are (position 4 | q 1 | units 4), a batch segment's are, per slot that filled, maker 20 | slot 2 | n 1 |
    /// n x (index 1 | q 1 | units 4); a record's base amount is units x 10^q. A segment that filled nothing is left
    /// out.
    event Take(
        uint48 indexed marketKey,
        address indexed taker,
        uint256 packed,
        uint256 baseAmount,
        uint256 quote,
        uint256 fee,
        bytes fills
    );

    /// @notice Emitted by every batch operation, with the slot's two words after it
    /// @param maker The slot's maker
    /// @param packed kind 0-2 (0 post, 1 replace, 2 modify, 3 cancel, 4 claim) | the sub-orders acted on 8-11 | slot
    /// 128-143 | market key 144-191: the slot's version 144-159, the market id 160-191. The mask by kind: a post and a
    /// replace the orders rested (a replace's settled sub-orders are not in it: the two words show what is left), a
    /// modify the sub-orders it names (each settled if it was live and rested again), a cancel the live sub-orders it
    /// settled, a claim the sub-orders whose fills it paid
    /// @param word The slot's main word after the operation (`batchOf`): each sub-order's tick, q and open units, and
    /// its side (bit 246 + i, 1 a bid)
    /// @param set The slot's settlement word after the operation: each live sub-order's base (its open units as of this
    /// settlement; an empty sub-order's base is left over and counts for nothing)
    event BatchUpdated(address indexed maker, uint256 packed, uint256 word, uint256 set);

    /// @notice Emitted when tokens are deposited into an account
    /// @param user The account's owner
    /// @param token The token
    /// @param amount The amount
    event Deposit(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when tokens are withdrawn from an account
    /// @param user The account's owner
    /// @param token The token
    /// @param to The wallet paid
    /// @param amount The amount
    event Withdraw(address indexed user, address indexed token, address to, uint256 amount);

    /// @notice Emitted when the protocol's fee pot of a token, or for address(0) the listing fees, is paid out
    /// @param token The token, or address(0) for the native currency
    /// @param to The fee recipient
    /// @param amount The amount
    event FeesCollected(address indexed token, address to, uint256 amount);

    /// @notice Emitted when a flash is repaid (`flash`): the caller's account was credited `amount` of `token`, the
    /// callback ran, and the account was debited `amount` back. Logged after the callback's own events. An account's
    /// net change across the flash is the callback's work alone (the flash is free)
    /// @param borrower The caller
    /// @param token The token
    /// @param amount The amount credited and debited back
    event Flash(address indexed borrower, address indexed token, uint256 amount);

    /// @notice Emitted when the fee recipient changes
    /// @param feeRecipient The new fee recipient
    event FeeRecipientSet(address feeRecipient);

    /// @notice Emitted when the listing fee changes
    /// @param fee The native currency a listing pays from then on, in wei
    event ListingFeeSet(uint80 fee);

    /// @notice Emitted when pool positions are pre-written
    /// @param marketKey The market and the version whose positions were written: the id << 16 | the version
    /// @param from The first position
    /// @param n The number of positions, `from` .. `from + n - 1` (a position number is 32 bits: past 2^32 - 1 the
    /// range goes on from 0); those already written are left alone
    event PoolWarmed(uint48 indexed marketKey, uint32 from, uint256 n);

    /// @notice Emitted when a market is listed by `listMarketQuote` or `listMarketQuoteProprietary`
    /// @param marketId The market's id, which its config word carries
    /// @param base The base token
    /// @param quote The quote token
    /// @param config The market's config word C at version 1: its key (the tokens, the spacing, minQuote, the
    /// proprietary bit and the id), the fee and the maker share (the pair's share, else the global one)
    event MarketListed(uint32 indexed marketId, address base, address quote, uint256 config);

    /// @notice Emitted when a proprietary market is listed by `listMarketQuoteProprietary`, after its MarketListed
    /// @param marketId The market's id
    /// @param lister The lister, who chose the policy
    /// @param policy The market's policy, for good (IOloMarketPolicy)
    event ProprietaryMarketListed(uint32 indexed marketId, address indexed lister, address policy);

    /// @notice Emitted when the owner allows a lister to list proprietary markets, or stops allowing it
    /// @param lister The lister
    /// @param allowed Whether it may list proprietary markets from then on (the markets it listed trade on either way)
    event ProprietaryListerSet(address indexed lister, bool allowed);

    /// @notice Emitted when `setMarketFee` or `setMarketMakerShare` makes a market's next version: its C with the fee
    /// or the share rewritten and the version one more, the market's id and key unchanged. New orders rest in it from
    /// then on; orders resting in earlier versions fill at their fee, settle at their share, and cancel and claim
    /// @param marketId The market
    /// @param version The new version
    /// @param config The market's config word C at the new version
    event MarketConfigSet(uint32 indexed marketId, uint16 version, uint256 config);

    /// @notice Emitted when the global fee floor is set: at the contract's birth (its constructor's, 0 included) and by
    /// `setGlobalFeeFloor`
    /// @param feePpm The least fee a listing of a pair with no floor of its own may carry from then on, in ppm
    event GlobalFeeFloorSet(uint24 feePpm);

    /// @notice Emitted when a pair's fee floor is set
    /// @param token0 The pair's token of the lower address
    /// @param token1 The other token
    /// @param feePpm The least fee a listing of the pair, either token as base, may carry from then on, in ppm; it
    /// takes the global floor's place, below it too
    event PairFeeFloorSet(address indexed token0, address indexed token1, uint24 feePpm);

    /// @notice Emitted when a pair's fee floor is lifted: its listings fall back to the global floor
    /// @param token0 The pair's token of the lower address
    /// @param token1 The other token
    event PairFeeFloorLifted(address indexed token0, address indexed token1);

    /// @notice Emitted when the global maker share changes
    /// @param makerShareBps The share a listing of a pair with no share of its own gives its market from then on, in
    /// bps
    event GlobalMakerShareSet(uint16 makerShareBps);

    /// @notice Emitted when a pair's maker share is set
    /// @param token0 The pair's token of the lower address
    /// @param token1 The other token
    /// @param makerShareBps The share a listing of the pair, either token as base, gives its market from then on, in
    /// bps; it takes the global share's place, below it too
    event PairMakerShareSet(address indexed token0, address indexed token1, uint16 makerShareBps);

    /// @notice Emitted when a pair's maker share is lifted: its listings fall back to the global share
    /// @param token0 The pair's token of the lower address
    /// @param token1 The other token
    event PairMakerShareLifted(address indexed token0, address indexed token1);

    /// @notice The number of markets listed; market ids run from 1 to this
    function marketCount() external view returns (uint32);

    /// @notice The wallet `collectFees` pays
    function feeRecipient() external view returns (address);

    /// @notice The number of tokens in the registry; token ids run from 1 to this
    function tokenCount() external view returns (uint256);

    /// @notice A token's id in the registry, 0 if no listing registered it
    function tokenId(address token) external view returns (uint256);

    /// @notice The token with registry id `id`
    function tokenAddr(uint256 id) external view returns (address);

    /// @notice Whether `lister` may list proprietary markets (`setProprietaryListingAllowed`). Named for its selector,
    /// 0xf73c7555, which sorts after every hot entry's.
    function canListProprietaryMarkets(address lister) external view returns (bool);

    /// @notice The policy of proprietary market `marketId`, set at its listing for good; zero for any other id. Named
    /// for its selector, 0xfbcb14a4, which sorts after every hot entry's.
    function proprietaryMarketPolicy(uint32 marketId) external view returns (address);
}
