// SPDX-License-Identifier: MIT
// Copyright (c) 2026 YOU LI.
pragma solidity ^0.8.8;

/// @title OloBook's listing, admin, pre-warming and flash entries
/// @notice The OLO EVM contract forwards these to its extension, which runs them by delegatecall in the OLO EVM
/// contract's storage. Each checks the reentrancy lock (a flash at its start: its callback runs with the lock open).
interface IOloBookExt {
    /// @notice Lists a market (anyone may), at version 1. Its key K (the tokens, the spacing, minQuote, the
    /// proprietary bit, clear for a market listed here, and the id) is fixed for good: every later market call names
    /// the market by it. Its fee and maker share are its C's tag, with
    /// the version: a fee or share change makes the next version in place, and every pool position and batch slot is
    /// keyed by a version's C. Named for its selector, 0xfb2f1996, which sorts
    /// after every hot entry's: the dispatcher compares selectors in order, so a cold entry sorting early would cost
    /// every hot entry after it.
    /// @dev Every market prices on one grid (PriceGrid): a tick is a price per base wei in quote wei, P(t) = (100_000 +
    /// t % 900_000) x 10^(t / 900_000 - 43), ticks 1 .. 66,599,999 over 74 decades (P from about 10^-38 to 10^36), of
    /// which makers rest from 3,600,000 (decade 4, P 10^-34) up, so a market chooses no price range and no price leaves
    /// it. Amounts are base wei: an order stores its amount as units x 10^q (the smallest q with fewer than 2^30 units;
    /// exact below 2^30 wei, 9 or 10 significant figures above), and a taker fills any amount in whole units of the
    /// orders it reaches. A market keeps `sigFigs` significant figures: a maker's tick (a place, a modify, a batch
    /// sub-order, a takeThenRest's rest) must be a multiple of the spacing 10^(6 - sigFigs), 1, 10, 100 or 1000; takers
    /// fill whatever rests, and a take's entry ticks need no alignment. Every resting order is worth at least
    /// `minQuote` quote wei at its tick (SizeOutOfRange below it), so the minimum follows the quote token, not the
    /// price. Listing registers the market's tokens, each an address with code, and base is not quote; nothing else
    /// adds a token, and nothing else about one is checked. The fee is at least the pair's floor, when the owner set
    /// one, else the global floor, the one the contract was born with until the owner moves it (FeeTooLow;
    /// `pairDefaultsOf`). One listing per set of parameters (the tokens, the fee, the spacing and minQuote, as listed:
    /// a later fee change neither frees them nor takes others); the market's id goes into its config word, so C names
    /// its market, at version 1. The lister does not choose the market's maker share: it starts at the pair's share,
    /// when the owner set one, else the global share, 0 as deployed (the protocol takes the whole fee;
    /// `pairDefaultsOf`), and the market keeps it until `setMarketMakerShare`. A listing sends
    /// the listing fee exactly, `listingFeeCurrent` wei of the native currency (BadListingFee otherwise), 0 until the
    /// owner sets one; the fees stay in the contract for `collectFees(address(0))`.
    /// @param base The base token, a contract
    /// @param quote The quote token, a contract other than the base
    /// @param feePpm The taker fee, parts per million of the quote amount, at most 1,000,000 and at least the floor
    /// @param sigFigs The market's significant figures, 6 to 3: makers rest on every tick, or every 10th, 100th or
    /// 1000th (PriceGrid.spacingOf)
    /// @param minQuote The least a resting order is worth at its tick, in quote wei (0: any order of one unit or more)
    /// @param positionsToWarm Pool positions 0 .. positionsToWarm - 1 to pre-write now, at the lister's expense
    /// @return marketId The new market's id
    function listMarketQuote(
        address base,
        address quote,
        uint24 feePpm,
        uint8 sigFigs,
        uint96 minQuote,
        uint16 positionsToWarm
    ) external payable returns (uint32 marketId);

    /// @notice Lists a proprietary market: as `listMarketQuote` in every other way (the checks, the fee floor, the
    /// maker share, the listing fee, version 1, and fee and share changes after), with the market's key bit
    /// C_PROPRIETARY set and a policy that decides who trades there (IOloMarketPolicy). Only a lister the owner allows
    /// (`setProprietaryListingAllowed`; NotProprietaryLister otherwise) lists one, and names the policy itself; the
    /// contract keeps it for good, so a lister that wants to change its rules puts them behind an address it can
    /// upgrade. The policy admits the caller of every entry that makes (a place, a modify, a batch post, replace or
    /// modify, a multicall's PLACE or MODIFY, a takeThenRest's rest) or takes (a take, a takeThenRest) there,
    /// NotAdmitted otherwise; makers are asked when they rest or change an order, not when it fills, so an order rested
    /// by a maker the policy admitted then fills after the policy stops admitting it, until the maker cancels it.
    /// Nothing that only leaves asks the policy (a cancel, a claim, a batch cancel or claim, a multicall's CANCEL and
    /// CLAIM, deposits and withdrawals): no policy holds anyone's funds. The bit is part of the parameters a listing is
    /// keyed by, so a proprietary market and an open one of the same tokens, fee, spacing and minQuote are two markets,
    /// and the same parameters list once as proprietary (MarketExists for any other lister after). A lister the owner
    /// stops allowing lists no more, and its markets trade on under their policies. Logs MarketListed (C with the bit)
    /// and then ProprietaryMarketListed (the lister and the policy). Named, and its parameters typed, for its selector,
    /// 0xf5a34949, which sorts after every hot entry's.
    /// @param base The base token, a contract
    /// @param quote The quote token, a contract other than the base
    /// @param feePpm The taker fee, as `listMarketQuote`'s
    /// @param sigFigs The market's significant figures, 6 to 3
    /// @param minQuote The least a resting order is worth at its tick, in quote wei (0: any order of one unit or more)
    /// @param positionsToWarm Pool positions 0 .. positionsToWarm - 1 to pre-write now, at the lister's expense
    /// @param policy The market's policy, an address with code (BadPolicy otherwise); the listing does not call it
    /// (IOloMarketPolicy: a policy reads the market's id from each call, the id not being known before the listing)
    /// @return marketId The new market's id
    function listMarketQuoteProprietary(
        address base,
        address quote,
        uint24 feePpm,
        uint8 sigFigs,
        uint96 minQuote,
        uint16 positionsToWarm,
        address policy
    ) external payable returns (uint32 marketId);

    /// @notice Owner only. Allows `lister` to list proprietary markets (`listMarketQuoteProprietary`), or stops
    /// allowing it. The markets it listed keep trading either way, under the policies they were listed with. Named,
    /// and its parameters typed, for its selector, 0xfb9a4cdb, which sorts after every hot entry's.
    /// @param lister The lister
    /// @param allowed Whether it may list proprietary markets
    function setProprietaryListingAllowed(address lister, bool allowed) external;

    /// @notice Owner only. Sets a market's maker share, the makers' part of the fee their fills earn, paid when they
    /// settle (the protocol's fee pot takes the rest), for the orders placed from now on: the market's next version, in
    /// place (`MarketConfigSet`). The market keeps its id and its key K; its C's share field changes and its version is
    /// one more. Orders resting in earlier versions keep their C: their fills, taken before or after the change, settle
    /// at their version's share, so a change never reprices a fill already made. New orders rest in the new version,
    /// every pool position and batch slot of which is cold: the first order in each pays a fresh write again (a place
    /// in a position used before about 37,000 gas becomes about 54,000; a 4-order batch post in a used slot about
    /// 45,000 becomes about 82,000), once a position or slot. This call warms nothing (a fee change can warm as it
    /// goes, `setMarketFee`'s positionsToWarm); pool positions can be warmed after it (`warmPool`, anyone may pay),
    /// batch slots cannot, being each maker's own. The orders resting in older versions stay there until settled.
    /// Named, and its parameters typed, for its selector, 0xfb8d7721, which sorts after every hot entry's.
    /// @param marketId The market, listed (UnknownMarket otherwise)
    /// @param makerBps The share, at most 10,000 bps (MakerShareTooHigh), not the market's own (NoChange)
    function setMarketMakerShare(uint256 marketId, uint48 makerBps) external;

    /// @notice Owner only. Sets a market's fee for the orders placed from now on: the market's next version, in place
    /// (`MarketConfigSet`). The market keeps its id and its key K, so an upstream naming it by K places on as before;
    /// its C's fee field changes and its version is one more. Orders resting in earlier versions keep their C: they
    /// fill at their version's fee (a take names the version by the tag in its params), settle at its share, and cancel
    /// and claim, while a modify, a batch replace or modify of them reverts MarketFrozen, so their liquidity only
    /// drains. Setting a fee back to an earlier value makes a new version too. A fee and a share changed together are
    /// two versions: send them in one transaction, the share first and the fee second (the fee's call warms the
    /// version that stays). No fee floor and no listing fee apply. A change steps
    /// the fee by at most 1% of the quote, 10,000 ppm, up or down (FeeStepTooLarge): 0.12% goes to 1.12% at most, and
    /// a larger change is several. A market has 65,535 versions at most (TooManyVersions). Named, and its parameters
    /// typed, for its selector, 0xfe317271, which sorts after every hot entry's.
    /// @param marketId The market, listed (UnknownMarket otherwise)
    /// @param feePpm The new fee, at most 1,000,000 ppm, not the market's own (NoChange), and within 10,000 ppm of it
    /// (FeeStepTooLarge)
    /// @param positionsToWarm Pool positions 0 .. positionsToWarm - 1 of the new version to pre-write now, at the
    /// owner's expense
    function setMarketFee(uint256 marketId, uint24 feePpm, uint64 positionsToWarm) external;

    /// @notice Owner only. Sets the global fee floor: the least fee a listing of a pair with no floor of its own may
    /// carry (FeeTooLow below it). The contract is born with one, its constructor's third argument; this moves it, by the same rule, and by at most 1% of the quote, 10,000 ppm, up or down
    /// (FeeStepTooLarge; the constructor's floor takes no step). It moves the floor of every pair with no floor of its
    /// own by as much. Markets listed already keep their fee (`setMarketFee` moves one). Named, and its parameter
    /// typed, for its selector, 0xf4ea73bb, which sorts after every hot entry's.
    /// @param feePpm The floor, at most 1,000,000 ppm (BadMarketConfig) and within 10,000 ppm of the global floor now
    /// (FeeStepTooLarge); 0: none
    function setGlobalFeeFloor(uint32 feePpm) external;

    /// @notice Owner only. Sets or lifts a pair's fee floor. Set, it takes the global floor's place for the pair's
    /// listings, either token as base, above or below it (0: free, which is not the same as no floor); set before the
    /// tokens are ever listed, it holds for their first listing. Lifted, the pair's listings fall back to the global
    /// floor. The pair's maker share (`setPairMakerShare`) is kept either way. Markets listed already keep their fee.
    /// The floor a listing of the pair meets moves by at most 1% of the quote, 10,000 ppm, up or down
    /// (FeeStepTooLarge): from the pair's own floor when set, else the global one, to the floor set, or for a lift the
    /// global one. So a first set is within 10,000 ppm of the global floor, and a pair whose floor is further from the
    /// global one than that is stepped toward it before it is lifted. Named, and its parameters typed, for its
    /// selector, 0xffacda61, which sorts after every hot entry's.
    /// @param tokenA One token
    /// @param tokenB The other, in either order, not tokenA (BadMarketConfig)
    /// @param feePpm The floor, at most 1,000,000 ppm; 0 when lifting (BadMarketConfig otherwise); within 10,000 ppm of
    /// the floor the pair's listings meet now (FeeStepTooLarge)
    /// @param pairSet True sets the pair's floor, false lifts it
    function setPairFeeFloor(address tokenA, address tokenB, uint32 feePpm, bool pairSet) external;

    /// @notice Owner only. Sets the global maker share: the share a listing of a pair with no share of its own gives
    /// its market, 0 as deployed (the protocol takes the whole fee). Markets listed already keep their share
    /// (`setMarketMakerShare` changes one). Named, and its parameter typed, for its selector, 0xf461c1f5, which sorts
    /// after every hot entry's.
    /// @param makerBps The share, at most 10,000 bps (MakerShareTooHigh)
    function setGlobalMakerShare(uint24 makerBps) external;

    /// @notice Owner only. Sets or lifts a pair's maker share. Set, it takes the global share's place for the pair's
    /// listings, either token as base, above or below it (0: the protocol takes the whole fee, which is not the same as
    /// no share); set before the tokens are ever listed, it holds for their first listing. Lifted, the pair's listings
    /// fall back to the global share. The pair's fee floor (`setPairFeeFloor`) is kept either way. Markets listed
    /// already keep their share. Named, and its parameters typed, for its selector, 0xf7f5cbd8, which sorts after every
    /// hot entry's.
    /// @param tokenA One token
    /// @param tokenB The other, in either order, not tokenA (BadMarketConfig)
    /// @param makerBps The share, at most 10,000 bps (MakerShareTooHigh, checked before the lift's value, so a lift
    /// naming a value above it is MakerShareTooHigh too); 0 when lifting (BadMarketConfig otherwise)
    /// @param pairSet True sets the pair's share, false lifts it
    function setPairMakerShare(address tokenA, address tokenB, uint40 makerBps, bool pairSet) external;

    /// @notice Owner only. Sets the listing fee: the native currency every later listing sends, exactly. A hook
    /// against listing abuse (junk and look-alike markets otherwise cost only gas), 0 until set.
    /// @param fee The fee in wei, up to 2^80 - 1 (about 1.2 million ether)
    function setCurrentListingFee(uint80 fee) external;

    /// @notice Owner only. Sets the wallet `collectFees` pays.
    /// @param newFeeRecipient The new fee recipient, not zero and not the contract (BadAddress: a collection into the
    /// contract would zero the pot and strand it)
    function setFeeRecipient(address newFeeRecipient) external;

    /// @notice Pays the protocol's fee pot of a token (owner 0's account of it) to the fee recipient, or for
    /// address(0) the contract's whole balance of the native currency (the listing fees). Anyone may call.
    /// @param token A token a listing registered, or address(0) for the native currency
    /// @return amount The amount paid
    function collectFees(address token) external returns (uint256 amount);

    /// @notice Pre-writes pool positions that were never written, so the first order in each rewrites a nonzero
    /// word instead of a fresh one. Anyone may pay.
    /// @param marketId The market: its current version's positions are written
    /// @param from The first position
    /// @param n The number of positions, 1 to 512: `from` .. `from + n - 1`, on from 0 past the last position, 2^32 - 1
    function warmPool(uint32 marketId, uint32 from, uint256 n) external;

    /// @notice Credits `amount` of `token` to the caller's account, calls the caller back
    /// (`IOloFlashCallback.oloFlashCallback(token, amount, data)`), and debits the account by `amount` once the callback
    /// returns: a flash credit, free (no fee). The debit is the repayment: an account that then holds less than
    /// `amount` reverts the call whole (InsufficientBalance), the callback's work with it. A token transferred to the
    /// OLO EVM contract directly credits no account and repays nothing: an account that holds the amount anyway
    /// repays from it, and the transferred token stays in the OLO EVM contract, counted nowhere. The OLO EVM contract is
    /// unlocked for the callback, so it may call any entry (a take, a place, a withdrawal, a deposit, another flash),
    /// each settling as it would outside a flash. A withdrawal moves the OLO EVM contract's own tokens out, so a flash
    /// lends whatever the OLO EVM contract holds of the token (orders' escrow, every account and the fee pot), to come
    /// back, by a deposit or by what the callback earns, before the callback returns. The credit is checked as any
    /// credit is (the account stays within 2^128 - 1: AmountOverflow), not against what the OLO EVM contract holds: a
    /// credit beyond it can be spent inside the OLO EVM contract, not withdrawn (the transfer fails), and is debited
    /// back either way. The caller must have code to call back: an address without any is BadAddress (an account that
    /// delegates to code, EIP-7702, has some). Not a market entry: no proprietary market's policy is asked (the entries
    /// the callback calls ask theirs). Checks the reentrancy lock at its start (Locked inside another call's token
    /// transfer). Logs Flash after the debit. Named for its selector, 0xf740f328, which sorts after every hot entry's.
    /// @param token A token a listing registered (UnknownToken otherwise)
    /// @param amount The credit, 1 to 2^128 - 1 (ZeroSize, AmountOverflow)
    /// @param data Passed to the callback as given
    function flash(address token, uint256 amount, bytes calldata data) external;
}
