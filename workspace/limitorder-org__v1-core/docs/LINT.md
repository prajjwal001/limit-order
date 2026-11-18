# OloBook lint triage

`forge lint src`, forge 1.8.5 (51a52c5): 182 warnings, none of which calls for a code change.
Each is a pattern the code uses on purpose, a value with a bound the code enforces (and a test holds), or a false
positive. This page says which, by rule and by function: line numbers move with every edit, so rerun the command
after a change and read new warnings against these classes.

| rule | count | verdict |
| --- | ---: | --- |
| unsafe-typecast | 103 | intentional or bounded: see below |
| require-revert-in-loop | 38 | by design: invalid input in a parse, fill or settle loop reverts the call |
| reentrancy-events | 6 | an event after a token transfer, under the reentrancy lock |
| reentrancy-events | 10 | false positive: no external call before the event |
| reentrancy-events | 1 | by design: `Flash` logs a flash once its callback has returned and the credit is debited back |
| reentrancy-no-eth | 1 | by design: a flash's debit, the repayment, follows its callback, which runs with the lock open on purpose |
| uninitialized-local | 10 | false positive: a cursor or counter from 0, 0 as the value meant, or a read only on the path that assigns |
| divide-before-multiply | 3 | intended: a floor the code takes on purpose (whole units, quote mode's n1) |
| divide-before-multiply | 1 | exact: a quotient and remainder split (quote mode's cap) |
| calls-loop | 4 | bounded: a multicall's commit moves at most four tokens |
| calls-loop | 1 | by design: a multicall run's first PLACE or MODIFY in a proprietary market asks its policy, a static call, once a run |
| incorrect-strict-equality | 1 | by design: a pull must deliver exactly the amount credited |
| missing-zero-check | 1 | by design: `transferOwnership(address(0))` withdraws a pending proposal |
| missing-zero-check | 1 | false positive: the constructor's fee recipient is checked in `_setFeeRecipient`, the extension by its code |
| missing-events-access-control | 1 | false positive: `setProprietaryListingAllowed` logs ProprietaryListerSet on the line after its write |

## unsafe-typecast (103)

| class | count | why it is safe |
| --- | ---: | --- |
| a field read from a packed word | 40 | the truncation is the field's width: the entries' params words (the settle flags `lockIf` reads and the entries check, a place's position, a cancel's, claim's and modify's position, a take's and a takeThenRest's mode, the rest's position and probes, `manageBatchSubs`'s flags and slot, `_newWalk`'s mode), a multicall op word (a PLACE's tick, side byte, amount and position, the position `multicall` compares with where the PLACE landed, a CANCEL's, CLAIM's or MODIFY's position, a MODIFY's new tick and amount, a DEPOSIT's or WITHDRAW's token id and 128-bit amount), C's fields (`MarketLib`: the token ids, the spacing, the fee, the maker share, the version, the id), the market key the Take and PoolWarmed events carry (C's top 48 bits, `uint48(c.marketKey())`) and the pool word's owner (`PoolLib.ownerOf`). An op's ticks are 4-byte fields that `makerTick` checks before use (MIN_MAKER_TICK .. MAX_TICK, on the spacing), and its amounts 14-byte fields, the OLO EVM contract's 112-bit input bound |
| a take list's fields | 8 | the list's layout, read from the calldata word by `bytes1` .. `bytes20` casts (its top bytes): a segment header's kind (1 byte) and length (2) in `_fillSegments`, a position entry's position (4) and tick (4) in `_fillList`, a group's maker (20), slot (2) and mask (1) and each named sub-order's tick (4) in `_fillBatches`. An entry's tick is only compared with the order's (`_worse`), so any 32-bit value is safe |
| bytes written one at a time into an event's data | 8 | `_noteLanded` writes a 32-bit position into a PLACE op's bytes 21-24 as `uint8(landed >> 24)` .. `uint8(landed)`; `_closeSegment` writes a segment's 3-byte fills length the same way (a segment's list is at most 65,535 bytes and its fills under 80,000: `test_position_segment_longest`, `test_batch_segment_longest`), and `_fillBatches` a group's fills count (at most 4) |
| an amount made signed, or a signed sum made unsigned | 28 | every such amount is far below 2^255 (the bounds below): the order operations' flows, `_batchFlows`' sums, a multicall PLACE's escrow, a DEPOSIT's or WITHDRAW's 128-bit amount, `_moveAccount`'s and `_settleFlow`'s `uint256(flow)` and `uint256(-flow)`, `_commit`'s and `_creditAfter`'s sums |
| a token id the registry bounds | 2 | `listMarketQuote` stores the two token ids in C's 32-bit fields; the registry caps ids at 2^32 - 1 (`TokenRegistryFull`, `test_token_registry_full`) |
| a market id read back from its listing word | 1 | `marketIdGivenListingWord` returns the word `_list` wrote, `++marketCount` (a uint32), so below 2^32; a word no listing wrote reads 0 |
| the grid's helpers for tests and callers | 5 | `PriceGrid.tickAt` and `tickAtOrBelow`, which the contract never calls: `int256(EXP_OFFSET)` and `int256(DECADES)` are 43 and 74; `tickAt`'s `uint256(exp10 + 43)` of an exponent below -43 wraps past 2^255, which `tickOf` refuses as off the grid (`test_tickOf_rejects_off_grid`), and `tickAtOrBelow`'s `uint256(d)` comes after it has returned MIN_TICK for d < 0 (`test_inverse_clamps`) |
| a value its setter checks first, narrowed to its field | 11 | `uint16(makerBps)` in `setGlobalMakerShare` (its store and GlobalMakerShareSet) and `setPairMakerShare` (PairMakerShareSet), each after `makerBps > BPS` (MakerShareTooHigh); `uint24(feePpm)` in PairFeeFloorSet and in `_setGlobalFeeFloor` (its store and GlobalFeeFloorSet), each after the 1,000,000 bound; `uint32(marketId)` in `_marketOf` (the market's lookup, for `setMarketMakerShare` and `setMarketFee`) and twice in `_setVersion` (the registry slot and MarketConfigSet), after `_marketOf`'s `marketId > marketCount`, a `uint32` (`test_market_share_unknown_ids`); and `pairDefaultsOf`'s `uint24(floor)` and `uint16(share)`, fields of 24 and 14 bits. `test_bounds_are_checked_before_narrowing` holds every setter's check before its narrowing (values like 2^16 whose low bits would fit) |

The 28 signed amounts and their bounds. An order's amount is units x 10^q base wei, units below 2^30 and q at most 25
(`OloMath.toUnits`; the contract's inputs are below 2^112), so below 2^114; a price is mantissa x 10^(d - 43) quote wei
a base wei, below 10^6 x 10^30 < 2^120 (`PriceGrid`); so an order's quote (an escrow, a refund, proceeds) is below
2^234, and its fee, at most the quote (a listing caps feePpm at 1,000,000, and only a listed market has orders), below
2^234. `test_extreme_top_of_grid`, `test_amounts_at_the_bounds` and `test_batch_at_the_top` run the largest amounts at
the grid's top through the order and batch operations and check each flow exactly.

- `int256(quoteAmt)` and `int256(baseAmt)` in `_cancelOp` and `_claimOp`, and the seven casts of `_modifyOp`
  (`int256(proceeds)`, `int256(proceeds + fee)`, a kept bid's `int256(fee)`, a bid's old refund plus the maker's part
  of the fee and its new escrow, an ask's old and new open amounts): a quote flow is proceeds or a refund plus at most
  the fee (the maker's part, `_splitFee`), below 2^235; a base flow is below 2^114; each difference is of two such.
- the four casts of `_batchFlows`: sums over a slot's four sub-orders, each bounded as a pool order (a sub-order's
  fills and open units together are its base, below 2^30 units), so below 2^237.
- `int256(escrow)` in `_marketOp` (a multicall PLACE): an ask's amount, below 2^114, or a bid's quote rounded up, below
  2^234.
- `int256(uint256(uint128(...)))` in `_tokenOp`: a DEPOSIT's or WITHDRAW's amount is a 128-bit field.
- `uint256(flow)` and `uint256(-flow)` in `_moveAccount` and `_settleFlow`, each after its sign test: one operation's
  flow (the bounds above) or one of `_commit`'s sums (the next item).
- `uint256(-makerFlow)`, `int256(fromCredit)`, `int256(need - fromCredit)`, `uint256(-wallet)` and
  `uint256(entry.wallet)` in `_commit`, and `uint256(credit)` and `uint256(-credit)` in `_creditAfter`: sums of a
  multicall's flows. The ledger adds them with checked arithmetic (the PLACE's escrow, `_ledgerFlows`, `_ledgerAdd`),
  so a sum past the int256 range reverts the call; `_commit`'s unchecked block adds the orders' net flow to the DEPOSIT
  and WITHDRAW sums and negates a negative one. The net flow of a token is below 2^235 per order the call touches (ops
  repeated on one order net out, give or take a wei of rounding each: a refund rounds down, an escrow up), and the
  DEPOSIT and WITHDRAW sums are below 2^128 per op. Each order touched is a storage word read and written, about
  5,000 gas, so a sum would reach 2^254 only in a call of 2^19 orders, over 2 x 10^9 gas: no sum of two wraps, and no
  negation meets `type(int256).min`. `testFuzz_ledger_vs_reference` holds the ledger's netting to a reference.

## reentrancy-events (16)

The 6 events emitted after a token transfer: `Deposit` (`_deposit`, after the pull), `Withdraw` (`_withdraw`, after the
push), `Placed` (`place`, after the escrow's pull when its settle flags fund it from the wallet; `takeThenRest`, after
the take's settlement), `Take` (`_finishTake`, after the taker's settlement) and `FeesCollected` (`collectFees`, after
the token transfer or, for `collectFees(address(0))`, the native payment). Each entry that moves a token or the native
currency holds the transient lock for the call: `lock`, or `lockIf` on the flags that make it call out (a place's, a
modify's and a batch operation's settle flags, a cancel's and a claim's WALLET, a take's WALLET). Every entry that moves
money or orders, lists, warms, sets a market or fee parameter or allows a lister checks the lock, so a token's or a
recipient's callback can run none of them and no such event can come between: the logs come in the order the state
changed. The two ownership entries, `transferOwnership` and `acceptOwnership`, do not check the lock: they touch no
balance, order or market, and only the owner and the proposed owner can call them. The tests
`test_no_entry_runs_inside_a_transfer`, `test_wallet_entries_hold_the_lock`, `test_wallet_take_holds_the_lock` and
`test_reentrancy_matrix` hold this for every entry that checks the lock, and `test_native_payment_refused_or_reentered`
for the native payment.

The other 10 make no external call before the event: `MarketListed` (`listMarketQuote`, which takes the listing fee as
`msg.value` and reads a token's code size but calls nothing), `ProprietaryMarketListed` (`listMarketQuoteProprietary`,
the same, and the policy's code size, after the listing's own writes), `MarketConfigSet` (`_setVersion`, for
`setMarketFee` and `setMarketMakerShare`), `PoolWarmed` (`_warmPool`), and the maker events, which come before the
operation settles (`_settleFlows` follows them): `Claimed` and `Cancelled` (`cancel`), `Claimed` (`claim`), `Claimed`
and `Modified` (`_modifyEntry`), and `BatchUpdated` (`_manageBatch`). The lint counts inline assembly as an external
call, through internal and library calls, and each of these functions runs OloSlots' slot hashes, loads or stores first,
which call no other contract. The admin events of `setGlobalMakerShare`, `setPairMakerShare`, `_setGlobalFeeFloor`
(`setGlobalFeeFloor`'s and the OLO EVM contract's constructor's), `setPairFeeFloor`, `setCurrentListingFee` and
`_setFeeRecipient`, whose functions run no assembly, are not flagged.

## flash: reentrancy-events (1) and reentrancy-no-eth (1)

`flash` calls its caller back (`IOloFlashCallback.oloFlashCallback`) between the credit and the debit, with the lock
open, so the callback may call any entry: that is what a flash is. After the call come the debit, `_debit` on the
caller's account (reentrancy-no-eth: `_accounts` written after an external call), and `Flash` (reentrancy-events).
The debit reads the account as the callback left it, fresh, and is the repayment; nothing read before the call is
used after it but the token's id, the amount and the caller, which no callback changes. `Flash` comes after every event
the callback's calls logged, and only once the flash is repaid. A flash checks the lock first, so no token's callback
during another call's transfer can start one (`test_reentrancy_matrix`'s sixteenth entry); `IOloBookExt.flash` says
what a flash lends and how it comes back.

## divide-before-multiply (4)

All four are in src/base/OloBookTakes.sol, and each is a floor the code takes on purpose or a division that is exact
by construction: none drops precision the result needs.

- **Whole units, in `_fillList` and `_fillBatches` (2).** In base mode `x = remaining / unit` (then at most the order's
  open units) and `amount = x * unit`. An order holds whole units of 10^q base wei and a fill moves whole units (its
  word's open units drop by x), so x is the most whole units within what is left and `amount` is exactly what they
  are; the part of `remaining` below one unit is not filled there and walks on down the list (the next order's q may
  be smaller) or stays with the taker. In quote mode x is `_affordable`'s, itself a floor (the most units the budget
  still affords), and `amount` the same exact product. `test_take_ends_inside_a_q_order`,
  `test_q_order_and_the_walk_after_it` and `testFuzz_pool_takes_match_the_reference` hold the fills to whole units.
- **Quote mode's budget, in `_quoteBudget` (1).** `n1 = amount * PPM / (PPM + ppm)` is floor(A / (1 + f)), the
  integer the budget is derived from (OloBookTakes' note 4: every Q up to n1 passes, a Q in (n1, n1 + 1] passes
  while Q x f <= A - n1 - 1, and none past n1 + 1 does). The flagged `n1 * ppm >= n2` does not scale that floor back
  up: it compares n1 / 1 with n2 / feePpm by cross-multiplying, exact for positive denominators, to return the larger
  as (n, y). A is below 2^112, so n1 x feePpm is below 2^131 and n2 = (A - n1 - 1) x 10^6 below 2^132.
- **Quote mode's cap, in `_quoteCap` (1).** floor(n x 10^k / y), for a decade below 43 (k = 43 - decade), is computed
  as floor(n / y) x 10^k + floor((n mod y) x 10^k / y): with n = whole x y + r, n x 10^k / y = whole x 10^k +
  r x 10^k / y and whole x 10^k is an integer, so the two floors are the same number. The split is there because
  n x 10^43 (n below 2^132) would pass 2^256; whole is below 2^113, so the result is below (whole + 1) x 10^43 < 2^256,
  and r x 10^k is below 10^6 x 10^43 < 2^163.

`testFuzz_takes_match_the_reference` (OloQuoteRef.t.sol) holds quote mode's units, order by order, to a 512-bit
reference that finds them by binary search on the budget, and `testFuzz_quote_mode_never_exceeds` holds what a take
pays or receives within its amount over the makers' whole grid and every fee.

## The others

- **require-revert-in-loop (38).** Every check a loop can reach reverts the whole call. The multicall's op loop (22):
  the stream's own checks (an op cut short or of an unknown code, a token id no listing registered, a market index past
  the header: BadOp), the market's version (a header K resolved when the stream switches to it, `_current`:
  UnknownMarket; a header C checked current at its first PLACE or MODIFY, `_checkCurrent`: MarketFrozen or
  UnknownMarket), a proprietary market's policy at that first PLACE or MODIFY (`_admit`: NotAdmitted) and every check of
  the ops it runs: a PLACE's tick (`_marketOp`), its flags and busy positions (SlotBusy, in `_placeOp`'s probe loop); a
  PLACE's or MODIFY's size (`_restAmount`); a CANCEL's, CLAIM's and MODIFY's order and owner, a CLAIM's fills and a
  MODIFY's tick and NoChange (`_cancelOp`, `_claimOp`, `_modifyOp`); a fifth token (`_entryOf`, TooManyTokens); and the
  pot's bound (`_creditPot`, through `_splitFee`). `_commit`'s loops (4): an account's bound and balance (`_credit`,
  `_debit`, through `_moveAccount`), a short delivery (`_pull`, FeeOnTransfer) and a failed transfer (`SafeTransfer`,
  TransferFailed). A take's walk of its list (12): a segment past the list or of an unknown kind (`_fillSegments`), a
  position segment of no whole number of entries (`_fillList`), a group past its segment or with a mask naming no
  sub-order or one past 3 (`_fillBatches`), the exact sum past its bound (`_accrue`, and `_affordable` before it
  scales: AmountOverflow, OloBookTakes' note 3), and a quote-mode sell's budget past 2^126 (`_quoteCap`: AmountOverflow,
  note 4). That is the intent: there is no partial success to keep. A take reverts
  AmountOverflow only when its exact quote aligned to the lowest decade it reached, Q x 10^(43 - low), reaches 2^235;
  makers rest at decade 4 or above, so a take worth less than 2^235 / 10^39, about 5.5e31 quote wei, never does
  (`test_a_reprice_to_the_floor_denies_only_takes_past_the_threshold`, `test_absurd_decades_overflow`); each of
  `_accrue`'s three bounds is the only one that stops a take of its own (`test_two_fills_past_the_sum_limit_revert`,
  `test_a_multiply_that_would_wrap_reverts`).
- **uninitialized-local (10).** `takeThenRest`'s `c` (the rest's version), `escrow`, `landed` and `placed` are set
  only when the rest is placed: `c`, `landed` and `placed` are read only then, and `escrow` 0 otherwise is the value
  meant (no rest to fund); `set` in
  `_manageBatch` is read from storage, for a post or a replace, only when the slot holds a live sub-order, and 0
  otherwise is the value meant (nothing to settle, and the settlement word is then always rewritten); `fee` in
  `_modifyOp` is set only when the order has fills, so 0 otherwise is the value meant; the loops' cursors and counter
  (`cursor` in `_fillSegments`, `_fillList` and `_fillBatches`, `i` in `_fillBatches`) start at 0.
- **calls-loop (5).** `_commit` pulls and pays per ledger entry (`_pull`'s two `balanceOf` calls, `SafeTransfer`'s
  `transferFrom` and `transfer`), at most four tokens a multicall (TooManyTokens,
  `test_multicall_ledger_holds_four_tokens`). A token whose transfer fails reverts the caller's own call only. And
  `_admit`'s static call to a proprietary market's policy, at a run's first PLACE or MODIFY in that market (once a
  run, `test_multicall_asks_once_a_run`): a policy that refuses or fails reverts the caller's own call; a static call
  changes no state.
- **incorrect-strict-equality (1).** `_pull` requires the OLO EVM contract's balance to grow by exactly the amount it
  credits: less is a fee-on-transfer token (`test_token_transfers_that_fail`) or a rebasing token's rounding, and more
  is refused too (`test_a_token_that_delivers_more_than_asked_is_refused`). A token with transfer hooks could make a
  deposit revert by sending the contract tokens mid-pull; that costs the depositor a retry and gains the sender nothing.
- **missing-events-access-control (1).** `setProprietaryListingAllowed` writes `canListProprietaryMarkets[lister]`,
  which `listMarketQuoteProprietary` checks, and logs ProprietaryListerSet(lister, allowed) on the next line; the lint
  does not see the event. `test_listing_refusals` and `test_a_removed_lister_s_market_trades_on` (OloProprietary)
  expect it.
- **missing-zero-check (2).** `transferOwnership(address(0))` withdraws a pending proposal, as `IOwned2Step` says;
  ownership moves only when the proposed owner accepts, so it cannot be lost to a zero address. The constructor's
  addresses are checked where the lint does not follow: the fee recipient in `_setFeeRecipient` (zero or the OLO EVM
  contract: BadAddress), the extension by its code (zero has none: BadAddress).

## OloSentinel (`forge lint sentinel`, 2026-11-12)

The OLO EVM contract's owner (`sentinel/OloSentinel.sol`): 27 warnings, none of which calls for a code change.

| rule | count | verdict |
| --- | ---: | --- |
| require-revert-in-loop | 11 | by design: `schedule`, `execute` and `cancel` take a list, and one op or key that fails reverts the call whole, as `keyOf`'s decoding checks do inside it |
| unsafe-typecast | 8 | bounded: `uint64(eta)` (eta is now plus a delay of at most 30 days), `uint64(block.timestamp)` twice (when an op was scheduled and when the stretch of ownership began: a time below 2^64), `bytes4(op)` and `bytes4(data)` (the selector, after `op.length >= 4`), a pair op's two `uint160` token words and a lister op's lister word (after `_requireBits(args, i, 160)`) |
| block-timestamp | 3 | by design: a timelock compares the time; a validator's leeway of seconds is nothing against a delay of a day or more |
| missing-zero-check | 3 | by design: a guardian of zero is none (the constructor, `setGuardian`), and `transferAdmin(0)` withdraws a proposal |
| calls-loop | 1 | by design: `execute` runs the admin's list, each op one call to the OLO EVM contract or to the sentinel itself |
| reentrancy-events | 1 | `Executed` after the op's call: the op is deleted before the call, the OLO EVM contract's owner entries call nothing outside it, and the sentinel's own settings call nothing, so no path re-enters with the op live |
