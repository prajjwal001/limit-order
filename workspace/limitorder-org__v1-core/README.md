# Open Limit Order v1-core

We introduce the Open Limit Order (OLO) Protocol, an open limit order primitive, fully on chain and with minimal state
and process. The contract enforces custody, settlement and a price bound on every fill, and the resulting OLO Book is
derived from the public log. Matching is open, fair and programmable: the taker names the orders it fills in its own
economic interest, and because the cheapest list is the price-sorted walk, that interest alone enforces the best price,
so public matching is self-governed.

## Contracts

| Contract | Role |
| --- | --- |
| `src/OloBook.sol` | The OLO EVM contract: accounts, pool orders, batch slots, takes over a list of segments, the multicall, views (a market's id from its listing parameters among them) |
| `src/OloBookExt.sol` | Delegatecall extension holding the cold entries: listing (open and proprietary markets, and its fee in the native currency), admin (fee floors, maker shares, a market's fee or share moved as its next version, the proprietary listers), pool pre-warming, and the flash credit (`flash`) |
| `src/OloTypes.sol` | Where the OLO EVM contract keeps things: the storage keys (`OloSlots`) and the word layouts of a pool position (`PoolLib`), an account (`AccountLib`) and a batch slot (`BatchLib`) |
| `src/base/OloBookStorage.sol` | The first of a chain of abstract contracts, one concern each (Storage -> Assets -> Orders -> Batches -> Takes -> Base): the shared constants, storage, the reentrancy lock, the listing check, the caller's account keys |
| `src/base/OloBookAssets.sol` | Balances: deposits and withdrawals, the account primitives, a single operation's flows settled by its flags, escrow, the taker's settlement, the fee split and the pot, transfers, the multicall's ledger |
| `src/base/OloBookOrders.sol` | The pool's single-order operations: place, cancel, claim, modify; the maker events' data word |
| `src/base/OloBookBatches.sol` | A maker's batch slots (up to four sub-orders, bids, asks or both, each with a side bit of its own, in two words, every one on chain) and the maker's five operations on a slot |
| `src/base/OloBookTakes.sol` | A take: its state, the walk of the list's segments, the position and batch segment loops, the exact quote's sum and its one rounding, quote mode's budget, the Take event |
| `src/base/OloBookBase.sol` | The end of the chain, inherited by OloBook and OloBookExt |
| `src/base/Owned2Step.sol` | Owner storage and the two-step transfer, inherited by the OLO EVM contract and its extension |
| `src/types/Market.sol` | A market's listing parameters, the fields of its config word C, and `MarketLib`, which reads and builds C |
| `src/libraries/PriceGrid.sol` | The one price grid every market shares: a tick's price, 6 significant figures over decades of ten, and the quote of an amount rounded down or up |
| `src/libraries/OloMath.sol` | The OLO EVM contract's arithmetic: powers of ten, and an order's units and precision |
| `src/libraries/Flags.sol` | Settlement bits: which flows go through the caller's wallet instead of their accounts |
| `src/libraries/SafeTransfer.sol` | ERC-20 transfers that accept tokens returning nothing and refuse addresses without code |
| `src/interfaces/` | MIT: `IOloBook`, `IOloBookBase`, `IOloBookExt`, `IOwned2Step`, `IERC20Minimal`; `IOloMarketPolicy`, what a proprietary market's policy answers, whether a caller may make or take there; `IOloFlashCallback`, what a flash's caller answers; `OloListings`, a library for integrations that packs the parameters a market was listed with into its listing word and asks `marketIdGivenListingWord` for the market's id; and `MarketWord`, a market's config word C: the key K (the tokens, the spacing, minQuote, whether the market is proprietary, and the id, fixed at the listing) and the tag (maker share, fee, version) that a fee or share change rewrites in place, as the market's next version |
| `sentinel/OloSentinel.sol` | The OLO EVM contract's owner: every owner call is an op the admin schedules and may run from a delay later (1 to 30 days) for 7 days, and the guardian may cancel; built apart from `src`, in a profile of its own |
| `sentinel/IOloSentinel.sol` | The sentinel's interface: the flow, the roles, the delay, the ops and their events |

## Build and test

```shell
git submodule update --init                 # lib/forge-std
FOUNDRY_PROFILE=hirun forge build src       # OloBook and OloBookExt as they ship (20,000 optimizer runs, out-hirun/)
FOUNDRY_PROFILE=sentinel forge build sentinel   # the sentinel as it ships (out-sentinel/), apart from src
forge build --sizes
forge test
forge test --isolate --match-contract GasBench -vv   # per-operation gas, printed by the tests
```

Foundry 1.x, solc 0.8.38. The tests deploy the OLO EVM contract from `out-hirun/` and the sentinel from `out-sentinel/`
when they exist, and fail if a source changed since that build; rebuild after any edit under `src/` or `sentinel/`.

## Tests

| File | What it covers |
| --- | --- |
| `test/OloBook.t.sol` | The pool path and the OLO EVM contract around it: place, cancel, claim, modify, take, takeThenRest, accounts, listing, the token registry and warming, the multicall, input checks |
| `test/OloPrecise.t.sol` | Amounts in base wei stored as units x 10^q, fills in whole units, one rounding per take, fill-or-kill's tolerance, takeThenRest with its own precision |
| `test/OloPreciseBatch.t.sol` | The two-word batch slot: the main word a take writes, the settlement word only a maker's operation touches, each sub-order's own precision |
| `test/OloPriceGrid.t.sol` | The price grid and the OLO EVM contract's money on it, from the bottom decade to the top |
| `test/OloSigFig.t.sol` | Markets of 6, 5, 4 or 3 significant figures: the listing and every maker entry on its tick spacing |
| `test/OloMakerFloor.t.sol` | The makers' price floor and takeThenRest's limit rule |
| `test/OloQuote.t.sol` | Quote-sized takes by worked example: a buy never pays, a sell never receives, more than its amount |
| `test/OloShare.t.sol` | The fee and the maker share on every settle |
| `test/OloMarketFee.t.sol` | Fee floors (global and a pair's) on listing, and `setMarketFee` as the market's next version: an older version's orders fill and settle at its fee, and nothing rests there again |
| `test/OloMakerShare.t.sol` | The maker share's three levels (global, a pair's, a market's) and `setMarketMakerShare` as the market's next version |
| `test/OloConstantKey.t.sol` | The constant market key K: versions side by side, each entry naming its version by the tag its params carry, a wrong tag finding no order |
| `test/OloModifyKept.t.sol` | A modify that keeps an order with fills to pay moves no escrow, as a claim moves none |
| `test/OloBatchMixed.t.sol` | A batch slot holding bids and asks: each sub-order rests on its own side, a take skips the named sub-orders on its own side, and a settle pays each on its own side, worked to the wei |
| `test/OloBatchSides.t.sol` | Each sub-order's side as a bit of its own, set from the params by a post, a replace and a modify alike: a kept ask paid as a claim pays, a sub-order filled to no open units keeping its side, a side cleared before an index rests again, params bit 3 refused for every kind |
| `test/OloFeeCap.t.sol` | A taker fee up to 100%: at 100% a sell that fills is refused (SellBelowFee) and a buy pays its quote twice; an older version keeps its fee; a quote-mode sell whose budget passes 2^126 is refused (AmountOverflow) |
| `test/OloFlash.t.sol` | The flash credit: the credit, the callback with the lock open, the debit as the repayment; every entry called inside a callback, nested flashes, a direct transfer repaying nothing, a caller without code, the extension called directly, and a flash as a deposit repaid (fuzz) |
| `test/OloMarketIdOf.t.sol` | `marketIdGivenListingWord` and `OloListings`: a market found by the parameters it was listed with, through fee and share changes, and zero for any word no listing wrote |
| `test/OloTakeLists.t.sol` | How a take's list is built: a ladder (each entry bounded by the next order's price, the limit last) against a dead position taken over first, and a dust bid left out of a sell's list |
| `test/OloProprietary.t.sol` | Proprietary markets: the listing and its refusals, who is asked by each entry and as which role, the exits never asking, a revoked maker's orders filling, every answer a policy may give, the bit naming the market |
| `test/OloProprietaryInvariant.t.sol` | Handler-based invariants of a proprietary market whose policy changes its mind at random: only the admitted trade, no exit refused, the OLO EVM contract solvent |
| `test/OloListingFee.t.sol` | The listing fee: exact payment, 0 until set, collected by `collectFees(address(0))`, refusing and re-entering recipients |
| `test/OloEvents.t.sol` | Every event decoded from the logs |
| `test/OloReplay.t.sol` | Every position and batch slot rebuilt from the logs alone (the OLO Book) and checked against the OLO EVM contract |
| `test/OloLayout.t.sol` | The OLO EVM contract and its extension lay their storage out alike (read from the artifacts' storageLayout) |
| `test/OloIntegration.t.sol` | A router's exactIn and exactOut swaps over the OLO EVM contract, through the wallet, including orders taken first by others |
| `test/OloMoneyModel.t.sol` | An exact model of the money flows (pool orders, takes, accounts, multicall) checked after every step of random sequences |
| `test/OloPreciseModel.t.sol` | Solvency under random use across precisions and a decade boundary, everyone leaving at the end |
| `test/OloInvariant.t.sol` | Handler-based invariants over five markets and tokens of 0 to 24 decimals: solvency, no value created, every take's caps and rounding |
| `test/OloSlotRef.t.sol` | The batch slot's operations and take groups against `SlotRef.sol`, their plainest statement, over random sequences |
| `test/OloPoolTakeRef.t.sol` | The position segment's loop against `PoolTakeRef.sol` over random pool orders |
| `test/OloQuoteRef.t.sol` | A take's money against `TakeRef.sol`: exact quotes in 512-bit integers, quote mode's units by binary search |
| `test/OloWideRef.t.sol` | The same reference over the whole makers' grid, random fees and amounts up to the largest |
| `test/OloLedgerRef.t.sol` | The multicall's ledger and a single operation's settlement against `LedgerRef.sol` under every settle flag |
| `test/OloSlotsHash.t.sol` | The storage keys' preimages (written in assembly) against `abi.encodePacked`, and `BatchLib`'s mask table |
| `test/OloAsmMemory.t.sol` | Every assembly block under junk memory, a misaligned free memory pointer and dirty argument bits (`Brutalizer`) |
| `test/OloCalldataJunk.t.sol` | Junk in the take list's padding and after the calldata changes no outcome, return, log or balance |
| `test/OloNoSpill.t.sol` | The OLO EVM contract reserves no memory for stack values its compiler could not keep on the stack |
| `test/OloSentinel.t.sol` | OloSentinel: the deployment, the roles, an op's window, one op a key |
| `test/OloSentinelOps.t.sol` | OloSentinel's ops: how they decode, each of the thirteen run, a revert, the delay's change, the rate a fee moves at, the events |
| `test/OloSentinelInvariant.t.sol` | Handler-based invariants of the sentinel under random ops: a key runs at most once a delay, no fee or floor moves more than 1% a run, the sentinel keeps the OLO EVM contract |
| `test/GasBenchOlo.t.sol`, `GasBenchPrecise.t.sol`, `GasBenchQuote.t.sol`, `GasBench7702.t.sol`, `GasBenchSentinel.t.sol`, `GasBenchProprietary.t.sol`, `GasBenchFlash.t.sol`, `GasBenchTwoSided.t.sol`, `GasBenchTwoSidedMixed.t.sol` | Gas benches (`GasBench7702` runs with `EIP7702=true`; `TwoSidedBench.sol` and `TwoSidedMixedBench.sol` set up the two-sided requotes) |
| `test/OloBase.sol`, `OloSentinelBase.sol`, `OloOps.sol`, `BatchView.sol` | Fixtures (the OLO EVM contract; the OLO EVM contract owned by a sentinel), call and list encoders, the batch slot's word reader |
| `test/SlotRef.sol`, `PoolTakeRef.sol`, `TakeRef.sol`, `LedgerRef.sol` | The plain-Solidity references the differential tests hold the OLO EVM contract to |
| `test/utils/` | `MockERC20`, `HostileTokens` (fee-on-transfer, reentrant, silent tokens), `Wide` (512-bit integers), `Brutalizer` and `AsmHarness` (the assembly under junk) |

## Documentation

- [docs/ASSEMBLY.md](docs/ASSEMBLY.md): every inline assembly block, one row each: what it does, why it is assembly,
  what it relies on, what memory it touches, and the tests that hold it; the rules, and the tests around the Solidity
- [docs/LINT.md](docs/LINT.md): the `forge lint src` and `forge lint sentinel` triage: every warning class, and why
  none calls for a change

## License

Source-available, not open source (the interfaces aside). Open Limit Order v1 Core is licensed under the Business
Source License 1.1 (BUSL-1.1): see [LICENSE](LICENSE) for the Licensor, the Change Date and the Change License, and
[NOTICE](NOTICE). The interfaces, `src/interfaces/`, are MIT ([LICENSE-MIT](LICENSE-MIT)), so an integration may
import them in production. Patent pending. For licensing, contact licensing@limitorder.org. `lib/forge-std` keeps its
own license (MIT or Apache-2.0).
