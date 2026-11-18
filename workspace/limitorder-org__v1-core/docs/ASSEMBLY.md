# OloBook inline assembly: the index

Every inline assembly block of the OLO EVM contract, one row each, for audit: what it does, why it is assembly, what it
relies on, what memory it touches, and what holds it: 10 blocks, 41 lines of about 3,500 (1%). The rule: **assembly
decides nothing about money.** Pricing, fills, fees and their rounding, the state words, the take list walk and the
ledger are Solidity; assembly stays where it has a one-line contract Solidity cannot express (a raw storage slot, a
storage variable's slot number, a proxy forward, a word into `bytes` at an offset, a word out of calldata `bytes` with
no bounds check of its own) or where the Solidity form costs a hash's worth on every operation (the three slot preimages
over the scratch space).

The take loops, the batch slot's walk, the account flows and the ledger, and the multicall's reads were once assembly
too (39 blocks, 620 lines, 17%). They are Solidity now, held by the twins, models and pins below.

## The rules

1. **Where.** A block is a leaf with a one-line contract: a hash over the scratch space, a raw slot, a storage
   variable's slot number, a proxy forward, a word into `bytes`. No loop, no arithmetic on amounts, no check that
   decides money. What runs once an order is Solidity too, with `unchecked` and a stated bound where the checks were measured to cost.
2. **Pinned byte for byte.** Each block has a test that holds it to the plain statement of what it does: the preimages
   spelled out with `abi.encodePacked` (test/OloSlotsHash.t.sol), the writers and readers run clean and under junk
   memory, a misaligned free memory pointer and dirty argument bits with the same result (test/OloAsmMemory.t.sol).
3. **Memory-safe, and said where.** Every block is `assembly ("memory-safe")`, and its header names what it touches:
   the scratch space (0x00 .. 0x3f), the caller's `bytes` within its allocation, or, in the one block that ends the
   frame (`_delegate`: it returns or reverts and never comes back to Solidity), the memory from the free pointer on.
   Nothing else: no allocation, no temporary use past the free memory pointer by a block that returns to Solidity, no
   struct read by offset.
4. **Literals only.** A block reads file-level constants (the tags and masks in OloTypes.sol); inline assembly reads
   only literal constants, and a storage variable's `.slot`, a constant of the layout (`_marketSlot`). A value a caller
   supplies never passes through one: `_marketSlot` adds the id in Solidity, after the block.
5. **A new block pays its way in.** Before a block goes in: its Solidity form measured on the full bench (hirun,
   `forge test --isolate`, the three GasBench contracts), the number recorded in this index, a pinning test, an
   OloAsmMemory case, an index row. A loop goes back to assembly only with its twin (test/SlotRef.sol,
   test/PoolTakeRef.sol are still the loops' plainest statements), a differential fuzz, mutants, and the row.
6. **Bounds stated.** An `unchecked` block states its bound in a comment (units below 2^30 of 10^q with q at most 25,
   so a stored amount below 2^114; the mantissa below 2^20 and 10^(d - 43) at most 10^30; a take's quote sum below
   2^236; quote mode's budget n / y below 2^113; the fee below 2^20; amounts below 2^128 in an account), and the
   extremes are sent by OloPriceGrid (the top of the grid with the largest amounts, a fee past 2^128), OloSlotRef's
   `test_amounts_at_the_bounds`, OloQuote's `test_largest_amount_near_the_top_of_the_grid` and
   `test_the_largest_base_amount_is_base_mode`, and `test_absurd_decades_overflow` (OloPrecise).
7. **A change costs a bench.** via-IR's stack scheduling moves with small edits: a PR that touches the hot path runs
   the full bench before and after and says what moved. After editing the take walk, run OloNoSpill too: one word
   via-IR spills in any entry moves every call's free memory start (the take loops, inlined into one frame, once
   reserved 11 words, about 34 gas on every call of the OLO EVM contract; they are kept out of line since).

## The index

"Solidity form" is the measured cost of doing the same without assembly, on the full bench; "held by" names the tests
that would catch the block going wrong.

| block | lines | does | Solidity form | relies on | memory | held by |
| --- | ---: | --- | --- | --- | --- | --- |
| `OloSlots.orderSlot` | 5 | keccak256(C \| pos u32 \| 0x01), the pool position's slot | `abi.encodePacked` +160..+180 a hash: every order operation pays one, a take one per fill, a multicall PLACE two | the preimage's 37 bytes; pos read as its low 32 bits (POS_MASK) | scratch: two words written, 0x00 .. 0x3f, of which 0x00 .. 0x24 hashed | OloSlotsHash (the preimage spelled out, fuzzed), OloAsmMemory (junk in the scratch space, dirty pos), OloReplay (every word found by `orderWord`) |
| `OloSlots.batchSlot` | 5 | keccak256(C \| maker 20 \| slot u16 \| 0x02), a maker's batch slot | +160..+180 a hash | 55 bytes; slot read as its low 16 bits; the maker's upper bits shifted out | scratch: two words written, 0x00 .. 0x3f, of which 0x00 .. 0x36 hashed | OloSlotsHash, OloAsmMemory (dirty maker and slot), OloReplay (`batchOf`) |
| `OloSlots.listingSlot` | 5 | keccak256(the listing parameters' bytes 4-31 \| 0x04), one listing word per parameter set (MarketExists) | +160..+180 a hash, at a listing only | 29 bytes from 0x04: no id, so a listed set of parameters is found whatever id a word carries | scratch: 0x00 .. 0x20 written, of which 0x04 .. 0x20 hashed | OloSlotsHash (and `testFuzz_listingSlot_ignores_the_id`), the listing tests, OloAsmMemory |
| `OloBookStorage._marketSlot` | 3 | `_markets.slot`, the market registry's slot number (the id is added after the block, in Solidity: element id of the fixed array `MarketWord[1 << 32]` is at `_markets.slot + id`) | `_markets[id]` measured +52 a registry read (the index a uint32 too): its bound check and slot arithmetic, on every entry that reads the registry | `_markets` a fixed array of 2^32 words, the last state variable, so a uint32 id is always within it and the sum far below 2^256 | none | OloLayout (`_markets`' slot pinned, the last variable, 15 in all), `test_registry_slot_is_the_array_s` (the raw slot read back equals `configOf`), `test_version_cap` (a version written at the raw slot), every place, modify and batch rest |
| `OloSlots.load` / `store` | 3 + 3 | sload / sstore of a raw slot | none: Solidity has no raw slot (the StorageSlot pattern) | the slot from the three hashes | storage | every test that places, takes or settles; OloAsmMemory (round trips under junk) |
| `OloBook._delegate` | 8 | the calldata forwarded to OloBookExt by delegatecall, its return or revert data returned as is | none: Solidity returns raw bytes from a `fallback` but cannot bubble raw revert data (the Proxy pattern) | the extension's storage layout equals the OLO EVM contract's, and the extension has code (the constructor checks: a delegatecall to an address without code succeeds with nothing) | memory from the free pointer; the frame ends here (a copy to 0 would overwrite what a memory-safe block lets via-IR keep below the free pointer, the default build's 64-byte spill reserve at 0x80, and `impl`, read inside the block, could live there) | OloLayout (`test_book_and_extension_share_one_storage_layout`), every extension entry's tests |
| `OloBookTakes._put` | 3 | `word` into `b` at byte `offset` | a record written byte by byte about +250..+300 a fill; `bytes.concat` is O(n^2) and runs the 8,191-entry list out of gas | `b` reaches `offset + 32`: `_openFills` sizes the buffer at 2 x list + 64 (a record is at most twice its entry) and keeps a word to spare past every write | the caller's `bytes`, within its allocation | OloAsmMemory (the bytes outside the word untouched, the canary, the pointer and the zero slot intact, under junk and a misaligned pointer), OloEvents (the Take event decoded), OloReplay, `test_position_segment_longest` (OloBook), `test_batch_segment_longest` (OloPreciseBatch) |
| `OloBookTakes._trim` | 3 | `b`'s length set to `length` | a copy into an exactly sized array, about +30 a byte | `length` at most `b`'s size (the fills written so far) | the length word of the caller's `bytes` | OloAsmMemory, OloEvents (the fills' length in the event) |
| `OloBookTakes._word` | 3 | the 32 bytes of calldata `b` from byte `start`, read on past `b`'s end when fewer are left (the calldata after it, zero past the calldata's end) | each read a slice, its bounds check and a `bytes32` conversion (via-IR's shared helpers): measured 2026-11-09, +297 a one-order take, +144 each further pool entry, about +514 a batch group (a take of 100 orders +14,553, a batch take of 96 sub-orders +8,587) | every caller checks the bytes it uses are within its segment, and uses only those: a segment header's 3 bytes (`_fillSegments`: the segment's end within the list), whole 8-byte position entries (`_fillList`: a segment's length a multiple of 8), a group's 23-byte header and the ticks its mask names (`_fillBatches`: the group's end within the segment) | none: calldata only | OloAsmMemory (`testFuzz_word_reads_the_bytes_within`: the bytes within `b` whatever calldata follows), OloCalldataJunk (junk in the list's padding and after the calldata changes no outcome, return, log or balance), `test_take_list_malformed` and `test_a_group_short_of_its_ticks_reads_nothing_past_it` (every check, a group short of its ticks followed by a fillable segment), the take twins (OloPoolTakeRef, OloQuoteRef, OloWideRef), the mutants below |

Not applicable to OloAsmMemory: `_delegate` never returns to Solidity.

Outside the OLO EVM contract, its owner OloSentinel has one block of its own, 3 lines, in `execute`: an op whose call
fails reverts with the revert data its target gave, as it gave it (memory-safe: it reads the returned `bytes` within its
allocation and ends the frame). `test_a_revert_is_the_books` (OloSentinelOps) holds it.

## The rest of the net

What holds the Solidity that replaced the assembly, since an audit reads it as one:

- **Twins and differential fuzzes.** test/SlotRef.sol and OloSlotRef hold the two-word batch slot's operations and
  the batch segment's loop (base and quote mode) to their plainest statement (random operations, valid and not, and
  random takes, the same error, both words, balances, pot, fills and quote after every step); test/PoolTakeRef.sol
  and OloPoolTakeRef the position segment's loop; test/TakeRef.sol and OloQuoteRef the take's quote sum and quote
  mode's units against a 512-bit brute-force reference (test/utils/Wide.sol); test/LedgerRef.sol and
  OloLedgerRef the ledger and the account flow (random multicalls and flagged single operations over five tokens,
  every account and wallet balance and every error after each step).
- **Models and invariants.** OloMoneyModel (an exact model of the money flows, random sequences, everyone leaving at
  the end), OloInvariant (handler-based invariants over five markets and tokens of 0 to 24 decimals: solvency, no
  value created, every take's caps and rounding), OloReplay (every word rebuilt from the events alone),
  OloEvents (every event's layout), OloPreciseModel's solvency checks.
- **Pins.** OloSlotsHash (the preimages), OloLayout (the OLO EVM contract and the extension lay their storage out
  alike), OloAsmMemory (the blocks under junk; `_word` reads calldata, so its case is the bytes within `b` whatever
  follows), OloCalldataJunk (junk outside the take list changes nothing), OloNoSpill (the contract reserves no memory
  for spilled stack values: its runtime opens `6080604052`).
- **Mutants.** A mutant is the code with one plausible slip; the suite is run against each; one no test fails on is a
  gap. When the batch slot's walk and the position loop were assembly, OloSlotRef alone caught 20 of 20 mutants of the
  walk and OloPoolTakeRef 10 of 10 of the loop; of 22 mutants of the assembly ledger, 4 real gaps (a debit losing USED,
  the first-entry check, the walk's stride, the commit's end) were closed by LedgerRef's tests. On the ledger in
  Solidity (run before a single operation's flows moved into its entry, `_settleFlows`; S13's `_acctFlow` is gone):

| mutant | what it breaks | killed by |
| --- | --- | --- |
| S1 `_moveAccount` debit check reversed | every debit above the balance passes | the take and rounding fuzzes, the models (216 tests) |
| S2 debit check dropped | an overdraft wraps | `testFuzz_ledger_vs_reference`, `test_accounts`, `test_subs_extreme_parameters` |
| S3 a debit loses USED | an emptied account's word becomes 0 (its next credit a fresh 20k write) | `test_account_word_keeps_USED_when_an_escrow_empties_it` (OloLedgerRef) |
| S4 a credit writes no USED | the same on credits | the USED test, `test_accounts` |
| S5 overflow check dropped | a balance past 2^128 carries into unused bits | `test_amounts_stop_at_2_128`, `test_pot_holds_a_fee_past_an_account` |
| S6 the zero-flow guard dropped | a zero flow rewrites the word | equivalent: no caller passes a zero flow (`_commit` guards `credit != 0`, an escrow is at least 1, a deposit refuses 0); the only effect would be USED on an untouched account |
| S7 `_entryOf` loop one short | the last entry never found, a duplicate opened | `testFuzz_ledger_vs_reference`, `test_four_accounts_each_twice_settle_as_four_entries`, `test_four_token_ops_settle_every_entry` |
| S8 a fifth entry allowed | an index past the array (a panic) | the reference fuzz, the four-accounts test, `test_multicall_ledger_holds_four_tokens` |
| S9 `_entryOf` count bump dropped | entries never committed | the money solvency, the batch models (54 tests) |
| S10 `_ledgerAdd` credit and wallet swapped | a deposit becomes a withdrawal | the reference fuzz, `test_four_token_ops_settle_every_entry`, `test_multicall_deposit_withdraw_ops` |
| S11 `_commit` push reads the maker flow | the maker flow pushed | the models (26 tests) |
| S12 `_commit` wallet write-back dropped | pushes ignore the maker flow | the models (46 tests) |
| S13 `_acctFlow` direct inverted | direct flows go to an empty ledger | the fuzzes and the models (182 tests) |
| S14 AUTO ignores the credit | the wallet pulls the whole need | the batch models, the reference fuzz, `test_auto_funding` |

  13 of 14 killed, the survivor equivalent; S3 and S7 are caught by the LedgerRef tests alone (the gaps the assembly
  ledger's mutants had shown), which is why the twin stays beside a Solidity ledger. On the money paths of amounts in
  base wei (quote mode's budget and cap, the affordability walk, fill-or-kill's tolerance, the mode checks, the maker
  events' q): 28 mutants, 25 killed on the first run, the 3 survivors closed by tests written for them.

  On the take list's reader, `_word` (2026-11-09), seven mutants, each run against the whole suite:

| mutant | what it breaks | killed by |
| --- | --- | --- |
| M1 the segment header check dropped (`cursor + 3 > list.length`) | nothing: a header past the list ends past it too, and the segment's end check (`segEnd > list.length`) reverts BadTakeList the same | equivalent |
| M2 the segment's end check dropped | a segment running past the list is walked | `test_take_list_malformed` |
| M3 whole position entries not required | a last entry's missing bytes read from what follows | `test_take_list_malformed`, `test_take_bad_list_refused_under_junk`, `test_take_skips_dead_wrong_side_and_repriced` |
| M4 the group header check dropped (`cursor + 23 > groups.length`) | nothing: a header past the segment has its ticks' end past it too (or a mask of 0 or past 15), and both revert BadTakeList the same | equivalent |
| M5 the group's ticks check dropped | a group short of the ticks its mask names reads them from what follows | `test_a_group_short_of_its_ticks_reads_nothing_past_it`, `test_take_list_malformed` |
| M6 `_word` reads one byte late | every list misread | 91 tests |
| M7 a group's tick read by sub-order index, not in mask order | a mask with a gap reads past the ticks it named | OloSlotRef, OloWideRef, the batch replay and event tests (6) |

  5 killed, 2 equivalent. M5 survived the first run: `test_take_list_malformed` encoded its short group's tick as 32
  bytes, so the group held enough bytes and the case reverted on its mask instead. With Solidity's slices removing
  that check still reverted (out of bounds), so the gap had no consequence; with `_word` it would have read the
  missing tick from the next segment. The case now has 4-byte ticks, and the new test sends a short group followed by
  a pool segment whose bytes, read as the tick, would let a sub-order fill.

## Running the checks

```
FOUNDRY_PROFILE=hirun forge build src && forge build && forge test       # everything, on the shipped bytecode
forge test --match-contract 'OloAsmMemory|OloSlotsHash|OloLayout|OloCalldataJunk|OloNoSpill'   # the blocks' own tests
forge test --match-contract 'OloSlotRef|OloPoolTakeRef|OloQuoteRef|OloLedgerRef'   # the twins
forge test --isolate --match-contract GasBench -vv | grep 'GAS '          # the bench, before and after a change
```
