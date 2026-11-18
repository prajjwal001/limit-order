// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {BatchView} from "./BatchView.sol";
import {OloBook} from "../src/OloBook.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {BatchLib, PoolWord} from "../src/OloTypes.sol";

/// Solvency under random use: an 18-decimal base against a 6-decimal quote, prices straddling a decade boundary,
/// amounts from 1e6 to 1e22 wei (q 0 to 13), a protocol share; random places, cancels, claims, modifies, takes (both
/// sides, base and quote mode, wallet and account, fill-or-kill with a tolerance, pool and batch entries mixed, bounds
/// loose and tight), takeThenRests, batch
/// posts / replaces / modifies / cancels / claims and multicalls, each of which may revert. After every step the OLO
/// EVM contract holds at least what it owes: every account and pot, and every live order's exact claims (an ask's open
/// base and its fills' quote and fee, a bid's fills' base and its open quote and fills' fee; a batch sub-order's fills
/// are its base less its open units). At the end everyone settles and leaves: base comes out to the wei (amounts are
/// base wei, never rounded in flight), quote leaves only roundings.
contract OloPreciseModelTest is OloBase {
    MockERC20 weth;
    MarketWord cm;
    uint256 constant CENTER = 26_100_000; // decade 29's first tick: P = 1e-9 (ETH at $1,000)
    uint256 constant SPREAD = 4_000;
    uint256 constant NPOS = 16;
    uint256 constant PPM_ = 300;
    address[4] actors;
    uint256 seed;
    uint256 steps;
    /// Successful operations by kind: place, cancel, claim, modify, take, takeThenRest, batch, multicall; and takes
    /// that filled across two decades.
    uint256[9] ok;

    function setUp() public {
        _deploy();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        uint32 id = book.listMarketQuote(address(weth), address(quote), uint24(PPM_), 6, 1, 0);
        book.setMarketMakerShare(id, 7_000);
        cm = book.configOf(id); // the version at 70%
        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0xA000 + i));
            actors[i] = a;
            makers.push(a);
            weth.mint(a, 1e40);
            quote.mint(a, 1e40);
            vm.startPrank(a);
            weth.approve(address(book), type(uint256).max);
            quote.approve(address(book), type(uint256).max);
            book.deposit(address(weth), 1e30);
            book.deposit(address(quote), 1e30);
            vm.stopPrank();
        }
    }

    function _r() internal returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed)));
        return seed;
    }

    function _actor() internal returns (address) {
        return actors[_r() % 4];
    }

    function _tick() internal returns (uint256) {
        return CENTER - SPREAD + _r() % (2 * SPREAD + 1);
    }

    /// log-uniform-ish: a mantissa below 1e4 times 10^(2 .. 18)
    function _amount() internal returns (uint256) {
        uint256 r = _r();
        return (1 + r % 9_999) * 10 ** (2 + (r >> 32) % 17);
    }

    function _flags() internal returns (uint8) {
        uint256 r = _r() % 4;
        return r == 0 ? 0 : r == 1 ? 0x02 : r == 2 ? 0x04 : 0;
    }

    /// The model reaches every kind of operation: over a few seeds each kind succeeds many times.
    function test_model_reaches_every_operation() public {
        uint256[9] memory total;
        for (uint256 r; r < 12; ++r) {
            uint256 snap = vm.snapshotState();
            delete ok;
            testFuzz_solvency(uint256(keccak256(abi.encode("model", r))));
            for (uint256 k; k < 8; ++k) {
                total[k] += ok[k];
            }
            vm.revertToState(snap);
        }
        for (uint256 k; k < 8; ++k) {
            emit log_named_uint(string.concat("operation kind ", vm.toString(k)), total[k]);
            assertGe(total[k], 3, string.concat("operation kind ", vm.toString(k)));
        }
    }

    function testFuzz_solvency(uint256 s) public {
        seed = s;
        steps = 24 + s % 24;
        for (uint256 k; k < steps; ++k) {
            _step();
            _checkSolvent();
        }
        _everyoneLeaves3();
    }

    function _step() internal {
        uint256 op = _r() % 11;
        address a = _actor();
        if (op == 0 || op == 1) {
            uint8 probes = uint8(_r() % 3);
            uint32 pos = uint32(_r() % (NPOS - 2));
            uint256 t = _tick();
            uint256 amt = _amount();
            bool bid = _r() % 2 == 0;
            uint8 fl = _flags();
            vm.prank(a);
            try book.place(OloOps.key(cm), OloOps.placeW(bid, t, amt, pos, fl | (probes << 4))) {
                ++ok[0];
            } catch {}
        } else if (op == 2) {
            uint32 pos = _ownedPos(a, false);
            uint8 fl = _flags();
            vm.prank(a);
            try book.cancel(OloOps.key(cm), OloOps.tagW(cm, OloOps.posW(pos, fl & 0x02))) {
                ++ok[1];
            } catch {}
        } else if (op == 3) {
            uint32 pos = _ownedPos(a, true);
            vm.prank(a);
            try book.claim(OloOps.key(cm), OloOps.tagW(cm, OloOps.posW(pos, 0))) {
                ++ok[2];
            } catch {}
        } else if (op == 4) {
            uint32 pos = _ownedPos(a, false);
            uint256 t = _tick();
            uint256 amt = _amount();
            uint8 fl = _flags();
            vm.prank(a);
            try book.modify(OloOps.key(cm), OloOps.tagW(cm, OloOps.modifyW(pos, t, amt, fl))) {
                ++ok[3];
            } catch {}
        } else if (op == 5 || op == 6 || op == 10) {
            _randomTake(a, false);
        } else if (op == 7) {
            _randomTake(a, true);
        } else if (op == 8) {
            _randomBatch(a);
        } else {
            _randomMulticall(a);
        }
    }

    /// A live position `a` owns (with fills when `filled`), from a random start (mostly), or any position.
    function _ownedPos(address a, bool filled) internal returns (uint32) {
        uint256 start = _r();
        if (start % 8 != 0) {
            for (uint256 k; k < NPOS; ++k) {
                uint32 pos = uint32((start + k) % NPOS);
                PoolWord w = PoolWord.wrap(book.orderWord(cm, pos));
                if (w.isLive() && w.ownerOf() == a && (!filled || w.filledOf() != 0)) return pos;
            }
        }
        return uint32(start % NPOS);
    }

    /// A live position, from a random start (mostly), or any position.
    function _livePos() internal returns (uint32) {
        uint256 start = _r();
        if (start % 4 != 0) {
            for (uint256 k; k < NPOS; ++k) {
                uint32 pos = uint32((start + k) % NPOS);
                if (PoolWord.wrap(book.orderWord(cm, pos)).isLive()) return pos;
            }
        }
        return uint32(start % NPOS);
    }

    /// A take's amount: mostly as large as the orders or larger, so takes reach whole units of q > 0 orders.
    function _takeAmount() internal returns (uint256) {
        uint256 r = _r();
        if (r % 5 == 0) return 1e24;
        return (1 + r % 9_999) * 10 ** (6 + (r >> 32) % 15);
    }

    function _list(bool buy) internal returns (bytes memory list) {
        uint256 n = _r() % 6;
        bytes memory entries;
        for (uint256 i; i < n; ++i) {
            uint32 pos = _livePos();
            uint256 bound = _r() % 3 == 0 ? _tick() : (buy ? PriceGrid.MAX_TICK : 1);
            entries = bytes.concat(entries, OloOps.poolEntry(pos, bound));
        }
        bytes memory groups;
        uint256 g = _r() % 3;
        for (uint256 i; i < g; ++i) {
            address mk = _actor();
            uint8 mask = uint8(1 + _r() % 15);
            uint256 bound = _r() % 3 == 0 ? _tick() : (buy ? PriceGrid.MAX_TICK : 1);
            groups = bytes.concat(groups, OloOps.slotGroupAt(mk, uint16(_r() % 2), mask, bound));
        }
        if (_r() % 2 == 0) {
            if (entries.length != 0) list = bytes.concat(list, OloOps.poolList(entries));
            if (groups.length != 0) list = bytes.concat(list, OloOps.batchList(groups));
        } else {
            if (groups.length != 0) list = bytes.concat(list, OloOps.batchList(groups));
            if (entries.length != 0) list = bytes.concat(list, OloOps.poolList(entries));
        }
    }

    function _randomTake(address a, bool rest) internal {
        bool buy = _r() % 2 == 0;
        uint256 amt = _takeAmount();
        uint8 mode = uint8((_r() % 2) | (_r() % 4 == 0 ? 0x80 : 0));
        bytes memory list = _list(buy);
        if (!rest) {
            // a third of the takes in quote mode, their amount quote wei: never more paid or received than it
            bool inQuote = _r() % 3 == 0;
            if (inQuote) mode |= OloOps.QUOTE;
            uint256 maxLeft = _r() % (amt < 1 << 77 ? amt : 1 << 77); // within its 77 bits
            vm.prank(a);
            try book.take(OloOps.key(cm), list, OloOps.tagW(cm, OloOps.takeW(buy, amt, mode, maxLeft))) returns (
                uint256 got, uint256 quoteAmt
            ) {
                if (got != 0) ++ok[4];
                if (inQuote) assertLe(quoteAmt, amt, "quote mode within its amount");
                else assertLe(got, amt, "base mode within its amount");
                if (mode & OloOps.FOK != 0) assertLe(inQuote ? amt - quoteAmt : amt - got, maxLeft, "fill-or-kill");
            } catch {}
        } else {
            uint256 lim = _tick();
            uint32 pos = uint32(_r() % (NPOS - 2));
            mode = (mode & 0x01) | uint8((_r() % 3) << 4);
            vm.prank(a);
            try book.takeThenRest(OloOps.key(cm), list, OloOps.tagW(cm, OloOps.restW(buy, amt, lim, mode, pos))) {
                ++ok[5];
            } catch {}
        }
    }

    function _randomBatch(address a) internal {
        uint16 slot = uint16(_r() % 2);
        (uint256 word,) = book.batchOf(cm, a, slot);
        // mostly an operation the slot's state admits: a post into an empty slot, otherwise a replace, modify, cancel or
        // claim naming some sub-orders
        uint8 kind = uint8(_r() % 5);
        if (_r() % 4 != 0) kind = BatchLib.liveMask(word) == 0 ? 0 : uint8(1 + _r() % 4);
        bool bid = _r() % 2 == 0;
        uint8 mask = uint8(_r() % 16);
        if (mask == 0 && _r() % 4 != 0) mask = 0xf;
        uint256[4] memory o;
        for (uint256 i; i < 4; ++i) {
            if (_r() % 4 != 0) o[i] = OloOps.sub(_tick(), _amount());
        }
        uint256[3] memory w = OloOps.batchW(kind, bid, slot, _flags(), mask, o);
        vm.prank(a);
        (bool done,) = address(book).call(OloOps.batchCalldata(OloBook.manageBatchSubs.selector, cm, w));
        if (done) ++ok[6];
    }

    function _randomMulticall(address a) internal {
        uint256 n = 1 + _r() % 3;
        bytes memory ops;
        for (uint256 i; i < n; ++i) {
            uint256 k = _r() % 4;
            uint32 pos = k == 0 ? uint32(_r() % (NPOS - 2)) : _ownedPos(a, k == 2);
            if (k == 0) ops = bytes.concat(ops, OloOps.placeProbe(0, _tick(), _r() % 2 == 0, _amount(), pos, 2));
            else if (k == 1) ops = bytes.concat(ops, OloOps.cancel(0, pos));
            else if (k == 2) ops = bytes.concat(ops, OloOps.claim(0, pos));
            else ops = bytes.concat(ops, OloOps.modify(0, pos, _tick(), _amount()));
        }
        uint8 fl = _flags();
        vm.prank(a);
        try book.multicall(fl, bytes.concat(OloOps.header(cm), ops)) {
            ++ok[7];
        } catch {}
    }

    // ------------------------------------------------------------------ the checks

    /// What the contract owes on its live orders, exactly: base and quote.
    function _owed() internal view returns (uint256 baseOwed, uint256 quoteOwed) {
        for (uint32 pos; pos < NPOS; ++pos) {
            PoolWord w = PoolWord.wrap(book.orderWord(cm, pos));
            if (!w.isLive()) continue;
            uint256 unit = 10 ** w.qOf();
            (uint256 b, uint256 q) = _claims(w.isBidOf(), w.tickOf(), w.openOf() * unit, w.filledOf() * unit);
            baseOwed += b;
            quoteOwed += q;
        }
        for (uint256 i; i < 4; ++i) {
            for (uint16 s; s < 2; ++s) {
                (uint256 word, uint256 set) = book.batchOf(cm, actors[i], s);
                for (uint256 j; j < 4; ++j) {
                    uint256 sub = BatchLib.subAt(word, j);
                    if (sub == 0) continue; // empty: owes nothing (its base is left over and counts for nothing)
                    uint256 unit = 10 ** BatchLib.qOf(sub);
                    uint256 open = BatchLib.openOf(sub);
                    uint256 bse = BatchLib.baseAt(set, j);
                    assertGe(bse, open, "base >= open");
                    // each sub-order on its own side, D_j
                    bool bid = (BatchLib.bidMask(word) >> j) & 1 == 1;
                    (uint256 b, uint256 q) = _claims(bid, BatchLib.tickOf(sub), open * unit, (bse - open) * unit);
                    baseOwed += b;
                    quoteOwed += q;
                }
            }
        }
    }

    function _claims(bool isBid, uint256 tick, uint256 open, uint256 filled)
        internal
        pure
        returns (uint256 b, uint256 q)
    {
        uint256 fee = PriceGrid.feeDown(filled, tick, PPM_);
        if (isBid) return (filled, PriceGrid.quoteDown(open, tick) + fee);
        return (open, PriceGrid.quoteDown(filled, tick) + fee);
    }

    function _accountsOf(MockERC20 t) internal view returns (uint256 sum) {
        uint256 id = book.tokenId(address(t));
        for (uint256 i; i < 4; ++i) {
            sum += book.balanceOf(id, actors[i]);
        }
        sum += book.balanceOf(id, address(0));
    }

    function _checkSolvent() internal view {
        (uint256 baseOwed, uint256 quoteOwed) = _owed();
        assertGe(weth.balanceOf(address(book)), _accountsOf(weth) + baseOwed, "base solvent");
        assertGe(quote.balanceOf(address(book)), _accountsOf(quote) + quoteOwed, "quote solvent");
    }

    function _everyoneLeaves3() internal {
        for (uint256 i; i < 4; ++i) {
            address a = actors[i];
            for (uint32 pos; pos < NPOS; ++pos) {
                PoolWord w = PoolWord.wrap(book.orderWord(cm, pos));
                if (w.isLive() && w.ownerOf() == a) {
                    vm.prank(a);
                    book.cancel(OloOps.key(cm), OloOps.tagW(cm, OloOps.posW(pos, 0)));
                }
            }
            for (uint16 s; s < 2; ++s) {
                (uint256 word,) = book.batchOf(cm, a, s);
                if (BatchLib.liveMask(word) != 0) {
                    vm.prank(a);
                    _mb(cm, OloOps.maskW(OloOps.CANCEL, s, 0, 0xf));
                }
            }
        }
        (uint256 baseOwed, uint256 quoteOwed) = _owed();
        assertEq(baseOwed + quoteOwed, 0, "nothing left resting");
        uint256 wid = book.tokenId(address(weth));
        uint256 qid = book.tokenId(address(quote));
        for (uint256 i; i < 4; ++i) {
            address a = actors[i];
            vm.startPrank(a);
            book.withdraw(address(weth), book.balanceOf(wid, a));
            book.withdraw(address(quote), book.balanceOf(qid, a));
            vm.stopPrank();
        }
        book.collectFees(address(weth));
        book.collectFees(address(quote));
        assertEq(weth.balanceOf(address(book)), 0, "base to the wei");
        assertLe(quote.balanceOf(address(book)), 4 * steps + 4, "quote: roundings only");
    }
}
