// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {OloBook} from "../src/OloBook.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {OloOps} from "./OloOps.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";

using MarketLib for MarketWord;

/// Fixture for OloBook: a market on 6-decimal mocks (tick T = 34_200_000 is P = 1 quote wei per base wei, price 1.0;
/// fee 50 ppm, minQuote 1) and a funded taker. LOT = 1e6 base wei is main's lot of the same fixture: an amount of k
/// LOT at T + j is worth what k lots at main's T + j were. The OLO EVM contract is deployed from the hirun artifacts
/// (20,000 optimizer runs) when they exist, as it ships, and only if no source they were compiled from has changed
/// since.
abstract contract OloBase is Test {
    string internal constant BOOK = "out-hirun/OloBook.sol/OloBook.json";
    string internal constant EXT = "out-hirun/OloBookExt.sol/OloBookExt.json";

    OloBook book;
    MockERC20 base;
    MockERC20 quote;
    uint32 m;
    MarketWord c; // the market's config word
    uint256 baseId;
    uint256 quoteId;

    address taker = address(0xBEEF);
    /// The reference tick: P(T) = 1 (decade 38, mantissa 100_000), so a LOT at T is 1e6 quote wei (price 1.0). T is
    /// the bottom of decade 38: below it a LOT at T - k is 1_000_000 - k quote wei (decade 37), above it at T + k
    /// 1_000_000 + 10 k (PriceGrid).
    uint256 constant T = 34_200_000;
    /// main's lot of the fixture, in base wei
    uint256 constant LOT = 1e6;
    uint256 nMakers;
    address[] makers;
    /// Pool positions handed out by the fixture: the next free one, and the one each maker's `_plain` order took
    /// (with its tick, which a take's entry names).
    uint32 nextPos = 1000;
    mapping(address => uint32) posOf;
    mapping(address => uint256) tickOf;

    /// The owner sets the fixture market's maker share: the market's next version, which `c` follows from here (orders
    /// placed after rest there and settle at `bps`; orders placed before keep their version's C and share). The share
    /// the market has already is no change (NoChange): nothing is called, and `c` stays.
    function _setMarketShare(uint256 bps) internal {
        if (book.configOf(m).makerBps() == bps) return;
        book.setMarketMakerShare(m, uint48(bps));
        c = book.configOf(m);
    }

    /// The owner sets the fixture market's fee: the market's next version, which `c` follows from here.
    function _setMarketFee(uint256 ppm) internal {
        book.setMarketFee(m, uint24(ppm), 0);
        c = book.configOf(m);
    }

    /// The order id of position `pos` in the version `mc` names, as `place` returns it: pos 0-31 | the tag 206-255.
    function _orderId(MarketWord mc, uint32 pos) internal pure returns (uint256) {
        return OloOps.tagW(mc, pos);
    }

    /// The storage slot of the market registry (`_markets`, the contract's last state variable: OloLayout pins it), so
    /// a market's current C is at `MARKETS_SLOT + id`.
    uint256 internal constant MARKETS_SLOT = 10;

    /// A config word one bit off the fixture market's: no market's.
    function _wrongC() internal view returns (MarketWord) {
        return MarketWord.wrap(MarketWord.unwrap(c) ^ 1);
    }

    function _pos() internal returns (uint32) {
        return nextPos++;
    }

    /// A multicall payload on the fixture market: header plus `ops`.
    function _mc(bytes memory ops) internal view returns (bytes memory) {
        return bytes.concat(OloOps.header(c), ops);
    }

    /// Reverts unless every source the artifact at `path` was compiled from still has the hash its metadata recorded:
    /// a test must not run the build from before an edit.
    function _requireFresh(string memory path) internal view {
        _requireFresh(path, "FOUNDRY_PROFILE=hirun forge build src");
    }

    /// The same, naming `build` as the command that rebuilds the artifact.
    function _requireFresh(string memory path, string memory build) internal view {
        string memory json = vm.readFile(path);
        string[] memory files = vm.parseJsonKeys(json, ".metadata.sources");
        for (uint256 i; i < files.length; ++i) {
            bytes32 built = vm.parseJsonBytes32(json, string.concat(".metadata.sources['", files[i], "'].keccak256"));
            if (keccak256(bytes(vm.readFile(files[i]))) != built) {
                revert(string.concat(path, " is stale (", files[i], " changed): ", build));
            }
        }
    }

    function _deploy() internal {
        _deployWith(PriceGrid.MAX_SIG_FIGS);
    }

    /// The fixture at `sigFigs` significant figures: the same market, its makers on every 10^(6 - sigFigs)th tick (T
    /// is a multiple of 1000).
    function _deployWith(uint8 sigFigs) internal {
        bool hirun = vm.exists(BOOK) && vm.exists(EXT);
        if (hirun) {
            _requireFresh(BOOK);
            _requireFresh(EXT);
        }
        address ext = hirun ? vm.deployCode(EXT) : vm.deployCode("OloBookExt.sol:OloBookExt");
        // born with no global fee floor: the suites list at the fees they test (OloMarketFee tests a floor at birth)
        book = OloBook(
            hirun
                ? vm.deployCode(BOOK, abi.encode(address(this), ext, 0))
                : vm.deployCode("OloBook.sol:OloBook", abi.encode(address(this), ext, 0))
        );
        base = new MockERC20("USD Coin", "USDC", 6);
        quote = new MockERC20("Tether", "USDT", 6);
        // OLO_HIGH_IDS=true: the registry starts at 2^32 - 4096, so the fixture's tokens and every token a test lists
        // after them have ids that use all 32 bits of C's token fields and of the account keys
        if (vm.envOr("OLO_HIGH_IDS", false)) {
            vm.record();
            book.tokenCount();
            (bytes32[] memory reads,) = vm.accesses(address(book));
            vm.store(address(book), reads[0], bytes32(uint256(0xffff_f000)));
        }
        // the contract deploys at a global maker share of 0 (the protocol takes the whole fee); the suites were written
        // for markets listed at 10,000 and set their own share where they test one, so the fixture lists at 10,000, and
        // every market a test lists after it too (OloMakerShare tests the deployed 0 and the pair and market levels)
        book.setGlobalMakerShare(10_000);
        m = book.listMarketQuote(address(base), address(quote), 50, sigFigs, 1, 0);
        c = book.configOf(m);
        baseId = book.tokenId(address(base));
        quoteId = book.tokenId(address(quote));
        base.mint(taker, 1e30);
        quote.mint(taker, 1e30);
        vm.startPrank(taker);
        base.approve(address(book), type(uint256).max);
        quote.approve(address(book), type(uint256).max);
        vm.stopPrank();
    }

    /// A fresh maker with 1e24 of each token deposited and wallet approval to the contract.
    function _maker() internal returns (address account) {
        account = _makerAt(address(uint160(0x10000 + (++nMakers))));
    }

    /// `_maker` at a chosen address (the makers above have their top 128 bits zero).
    function _makerAt(address account) internal returns (address) {
        makers.push(account);
        base.mint(account, 1e30);
        quote.mint(account, 1e30);
        vm.startPrank(account);
        quote.approve(address(book), type(uint256).max);
        base.approve(address(book), type(uint256).max);
        book.deposit(address(quote), 1e24);
        book.deposit(address(base), 1e24);
        vm.stopPrank();
        return account;
    }

    /// A fresh maker resting `amount` base wei at `tick` in a fresh pool position (`posOf[account]`).
    function _plain(uint256 tick, bool isBid, uint256 amount) internal returns (address account) {
        account = _maker();
        uint32 pos = _pos();
        posOf[account] = pos;
        tickOf[account] = tick;
        vm.prank(account);
        book.place(OloOps.key(c), OloOps.placeW(isBid, tick, amount, pos, 0));
    }

    /// The pool entry of `a`'s `_plain` order: its position and tick.
    function _poolEntry(address a) internal view returns (bytes memory) {
        return OloOps.poolEntry(posOf[a], tickOf[a]);
    }

    /// The fixture market's maker tick spacing (1 at 6 significant figures).
    function _spacing() internal view returns (uint256) {
        return c.spacing();
    }

    /// Quote wei of one LOT (1e6 base wei) at `tick`, exact near T (decades 37 and 38).
    function _lq(uint256 tick) internal pure returns (uint256) {
        return PriceGrid.quoteDown(LOT, tick);
    }

    /// `amount` base wei at `tick`, rounded down and up.
    function _qd(uint256 amount, uint256 tick) internal pure returns (uint256) {
        return PriceGrid.quoteDown(amount, tick);
    }

    function _qu(uint256 amount, uint256 tick) internal pure returns (uint256) {
        return PriceGrid.quoteUp(amount, tick);
    }

    /// `manageBatchSubs` on market `mc` with its words as OloOps.batchW packs them; a revert is
    /// bubbled as is.
    function _mb(MarketWord mc, uint256[3] memory w) internal {
        (bool ok, bytes memory ret) = address(book).call(OloOps.batchCalldata(OloBook.manageBatchSubs.selector, mc, w));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// A batch slot's main word and settlement word.
    function _slotWords(MarketWord mc, address maker, uint16 s) internal view returns (uint256 word, uint256 set) {
        return book.batchOf(mc, maker, s);
    }

    /// The 3 bytes of `b` from byte `start`, big-endian: a Take event's segment length.
    function _u24(bytes memory b, uint256 start) internal pure returns (uint256) {
        return (uint256(uint8(b[start])) << 16) | (uint256(uint8(b[start + 1])) << 8) | uint8(b[start + 2]);
    }

    /// `a`'s balance of `token` in its account.
    function _bal(address a, MockERC20 token) internal view returns (uint256) {
        return book.balanceOf(book.tokenId(address(token)), a);
    }

    /// The protocol's fee pot of `token`.
    function _pot(MockERC20 token) internal view returns (uint256) {
        return book.balanceOf(book.tokenId(address(token)), address(0));
    }

    /// The next fee on the way from `fromPpm` to `toPpm`: `toPpm` when it is within 1% of the quote
    /// (MarketLib.MAX_FEE_STEP_PPM), else 1% toward it, the most one owner call moves a fee or a floor.
    function _stepToward(uint256 fromPpm, uint256 toPpm) internal pure returns (uint256) {
        uint256 step = MarketLib.MAX_FEE_STEP_PPM;
        if (toPpm > fromPpm + step) return fromPpm + step;
        if (toPpm + step < fromPpm) return fromPpm - step;
        return toPpm;
    }

    /// The owner moves the global fee floor to `toPpm`, 1% a call (at least one call).
    function _walkGlobalFloor(uint256 toPpm) internal {
        (, uint24 global,,,,) = book.pairDefaultsOf(address(base), address(quote));
        uint256 current = global;
        do {
            current = _stepToward(current, toPpm);
            book.setGlobalFeeFloor(uint32(current));
        } while (current != toPpm);
    }

    /// The owner sets the pair's fee floor to `toPpm`, 1% a call from the floor its listings meet now (its own, else
    /// the global one), so the pair's own floor is set at the end whatever it was.
    function _walkPairFloor(address tokenA, address tokenB, uint256 toPpm) internal {
        (uint24 floor,,,,,) = book.pairDefaultsOf(tokenA, tokenB);
        uint256 current = floor;
        do {
            current = _stepToward(current, toPpm);
            book.setPairFeeFloor(tokenA, tokenB, uint32(current), true);
        } while (current != toPpm);
    }

    /// A bench row, `GAS <key> <gas>`, for `grep GAS`.
    function _log(string memory k, uint256 g) internal pure {
        console2.log(string.concat("GAS ", k), g);
    }

    function _gas() internal view returns (uint256) {
        return vm.lastFrameGas().gasTotalUsed;
    }

    /// Frame gas less the refund it earns (capped at a fifth): what the sender pays.
    function _receipt() internal view returns (uint256) {
        Vm.Gas memory g = vm.lastFrameGas();
        uint256 used = g.gasTotalUsed;
        uint256 refund = uint256(uint64(g.gasRefunded));
        return used - (refund < used / 5 ? refund : used / 5);
    }

    /// The contract holds at least its fee pot in each token.
    function _solvent() internal view {
        assertGe(base.balanceOf(address(book)), _pot(base), "base solvent");
        assertGe(quote.balanceOf(address(book)), _pot(quote), "quote solvent");
    }

    /// Every maker and the taker withdraw both their balances in full, then the fee pots are collected: with no
    /// order left resting, an OLO EVM contract that owes more than it holds reverts here. Returns what stays in the
    /// contract.
    function _everyoneLeaves() internal returns (uint256 baseLeft, uint256 quoteLeft) {
        for (uint256 i; i <= makers.length; ++i) {
            address a = i < makers.length ? makers[i] : taker;
            vm.startPrank(a);
            book.withdraw(address(base), _bal(a, base));
            book.withdraw(address(quote), _bal(a, quote));
            vm.stopPrank();
        }
        book.collectFees(address(base));
        book.collectFees(address(quote));
        return (base.balanceOf(address(book)), quote.balanceOf(address(book)));
    }
}
