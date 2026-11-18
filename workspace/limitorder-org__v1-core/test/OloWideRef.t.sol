// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {TakeRef} from "./TakeRef.sol";
import {U512, Wide} from "./utils/Wide.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";

/// The take held to its brute-force reference (TakeRef.sol: the exact quote over one denominator, 10^43, in 512-bit
/// integers; quote mode's units by binary search on the specification) over the whole makers' grid: a market of a
/// random fee (0, 1, 333, 3,000, 499,999, 500,000, 999,938, 999,939, 999,999, 1,000,000 or any up to 100%),
/// six pool orders and two batch slots of four of both sides at ticks anywhere in decades 4 to 73 (around a random
/// centre, spread 0 to 73 decades), amounts up to 2^112 - 1 (q 0 to 25), all funded through the wallet; then three
/// takes, base or quote mode, buys and sells, over three segments of pool entries and batch groups that name orders at
/// their tick, either side of it, past every price, at a random tick, and twice. After every take: the verdict
/// (success, SellBelowFee where the reference says the fee passes the quote, AmountOverflow only where the reference's
/// own sum, aligned to the lowest decade the walk reached, is at least 2^235: Q x 10^(43 - low) >= 2^235, or where a
/// quote-mode sell's budget passes 2^126 at the first order the walk reaches: TakeRef.budgetRefused), the base,
/// the quote amount and every order's open units as the reference has them, and the amount never exceeded. At the end
/// every order is cancelled and the fee pots collected: base leaves the OLO EVM contract to the wei, quote keeps only
/// roundings.
contract OloWideRefTest is OloBase {
    using Wide for U512;

    MockERC20 x;
    MockERC20 y;

    function setUp() public {
        _deploy();
        x = new MockERC20("X", "X", 18);
        y = new MockERC20("Y", "Y", 18);
    }

    function _fundAll(address a, uint256 amt) internal {
        x.mint(a, amt);
        y.mint(a, amt);
        vm.startPrank(a);
        x.approve(address(book), type(uint256).max);
        y.approve(address(book), type(uint256).max);
        vm.stopPrank();
    }

    uint256 constant NP = 6;
    MarketWord fc;
    address[2] fm;
    uint256 ppm;
    // mirror of the OLO EVM contract during a take
    uint256[NP] mOpen;
    uint256[NP] mQ;
    uint256[NP] mTick;
    bool[NP] mBid;
    uint256[4][2] sOpen;
    uint256[4][2] sQ;
    uint256[4][2] sTick;
    bool[4][2] sBid; // each sub-order's side, D_i

    uint256 public okTakes;
    uint256 public overflowTakes;
    uint256 public filledTakes;
    uint256 public quoteFilled;
    uint256 public multiDecade;
    uint256 public belowFeeTakes;
    uint256 public refusedTakes;

    function _r(uint256 s, uint256 k) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(s, k)));
    }

    /// A maker's tick in a decade within `spread` of `center`, never below the makers' floor (decade 4).
    function _rtick(uint256 r, uint256 center, uint256 spread) internal pure returns (uint256 t) {
        uint256 lo = center > spread + 4 ? center - spread : 4;
        uint256 hi = center + spread > 73 ? 73 : center + spread;
        uint256 d = lo + r % (hi - lo + 1);
        t = d * 900_000 + (r >> 16) % 900_000;
        if (t > PriceGrid.MAX_TICK) t = PriceGrid.MAX_TICK;
    }

    function _ramount(uint256 r) internal pure returns (uint256 a) {
        uint256 e = r % 34; // 10^0 .. 10^33
        a = (1 + (r >> 8) % 999_999) * 10 ** e;
        if (a >= 1 << 112) a = (1 << 112) - 1 - (r >> 40) % 1e30;
    }

    function _readBook() internal {
        for (uint256 p; p < NP; ++p) {
            uint256 w = book.orderWord(fc, uint32(p));
            mTick[p] = w & 0x3ffffff;
            mQ[p] = (w >> 26) & 0x7f;
            mOpen[p] = (w >> 33) & ((1 << 30) - 1);
            mBid[p] = (w >> 93) & 1 == 1;
        }
        for (uint256 k; k < 2; ++k) {
            (uint256 w,) = book.batchOf(fc, fm[k], 0);
            for (uint256 i; i < 4; ++i) {
                uint256 sub = (w >> (2 + 61 * i)) & ((1 << 61) - 1);
                sBid[k][i] = (w >> (246 + i)) & 1 == 1;
                sTick[k][i] = sub & 0x3ffffff;
                sQ[k][i] = (sub >> 26) & 0x1f;
                sOpen[k][i] = sub >> 31;
            }
        }
    }

    function _worse(bool buy, uint256 tick, uint256 entry) internal pure returns (bool) {
        return buy ? tick > entry : tick < entry;
    }

    /// A random market, its orders and three takes against the reference, then everyone leaves.
    function testFuzz_wide_takes_match_the_reference(uint256 seed) public {
        ppm = [
            uint256(0), 1, 333, 3_000, 499_999, 500_000, 999_938, 999_939, 999_999, 1_000_000, _r(seed, 99) % 1_000_001
        ][seed % 11];
        fc = book.configOf(book.listMarketQuote(address(x), address(y), uint24(ppm), 6, 0, 0));
        uint256 center = 4 + _r(seed, 1) % 70;
        uint256 spread = [uint256(0), 2, 8, 20, 73][_r(seed, 2) % 5];
        fm[0] = address(0x1111);
        fm[1] = address(0x2222);
        _fundAll(fm[0], 0);
        _fundAll(fm[1], 0);
        _fundAll(taker, 0);
        // pool orders, wallet-funded
        for (uint256 p; p < NP; ++p) {
            uint256 r = _r(seed, 10 + p);
            bool bid = r & 1 == 1;
            uint256 tick = _rtick(r >> 8, center, spread);
            uint256 amt = _ramount(r >> 64);
            if (bid) {
                uint256 esc = PriceGrid.quoteUp(amt, tick);
                if (esc > 1 << 200) {
                    amt = 1 + (r >> 64) % 1e6;
                    esc = PriceGrid.quoteUp(amt, tick);
                }
                y.mint(fm[p % 2], esc);
            } else {
                x.mint(fm[p % 2], amt);
            }
            vm.prank(fm[p % 2]);
            book.place(OloOps.key(fc), OloOps.placeW(bid, tick, amt, uint32(p), 0x02));
        }
        // two batch slots of four
        for (uint256 k; k < 2; ++k) {
            uint256 r = _r(seed, 20 + k);
            bool bid = r & 1 == 1;
            uint256[4] memory o;
            for (uint256 i; i < 4; ++i) {
                uint256 ri = _r(r, i);
                uint256 tick = _rtick(ri, center, spread);
                uint256 amt = _ramount(ri >> 64);
                if (bid) {
                    uint256 esc = PriceGrid.quoteUp(amt, tick);
                    if (esc > 1 << 200) {
                        amt = 1 + (ri >> 64) % 1e6;
                        esc = PriceGrid.quoteUp(amt, tick);
                    }
                    y.mint(fm[k], esc);
                } else {
                    x.mint(fm[k], amt);
                }
                o[i] = OloOps.sub(tick, amt);
            }
            vm.prank(fm[k]);
            (bool ok, bytes memory ret) = address(book)
                .call(
                    OloOps.batchCalldata(
                        book.manageBatchSubs.selector, fc, OloOps.batchW(OloOps.POST, bid, 0, 0x02, 0, o)
                    )
                );
            require(ok, string(ret));
        }
        // a few takes
        for (uint256 tk; tk < 3; ++tk) {
            _oneTake(_r(seed, 100 + tk));
        }
        _leave();
    }

    function _oneTake(uint256 r) internal {
        _readBook();
        TakeRef.Take memory t;
        t.buy = r & 1 == 1;
        t.inQuote = (r >> 1) & 1 == 1;
        t.feePpm = ppm;
        // amount: random magnitude
        uint256 ra = _r(r, 7);
        t.amount = 1 + (ra >> 8) % ((1 << 112) - 1) / (10 ** (ra % 30));
        // list: 3 segments, each pool or batch, random entries (with duplicates and stale ticks)
        bytes memory list;
        TakeRef.Walk memory w;
        uint256 lowest = 74; // the lowest decade of an order the walk reached (74: none)
        bool refused; // a budget past 2^126, refused at the first order the walk reaches (nothing fills after)
        for (uint256 sgi; sgi < 3; ++sgi) {
            uint256 rs = _r(r, 1000 + sgi);
            if (rs & 1 == 0) {
                bytes memory entries;
                uint256 n = 1 + (rs >> 1) % 6;
                for (uint256 e; e < n; ++e) {
                    uint256 re = _r(rs, e);
                    uint256 p = re % NP;
                    uint256 et = _entryTick(re >> 8, t.buy, mTick[p]);
                    entries = bytes.concat(entries, OloOps.poolEntry(uint32(p), et));
                    // mirror
                    if (mOpen[p] == 0 || mBid[p] == t.buy || _worse(t.buy, mTick[p], et)) continue;
                    if (!t.inQuote && w.base == t.amount) continue;
                    if (refused || TakeRef.budgetRefused(t)) {
                        refused = true;
                        continue;
                    }
                    if (mTick[p] / 900_000 < lowest) lowest = mTick[p] / 900_000;
                    uint256 fx = TakeRef.fill(w, t, mOpen[p], mQ[p], mTick[p]);
                    mOpen[p] -= fx;
                }
                list = bytes.concat(list, OloOps.poolList(entries));
            } else {
                bytes memory groups;
                uint256 n = 1 + (rs >> 1) % 2;
                for (uint256 g; g < n; ++g) {
                    uint256 rg = _r(rs, g);
                    uint256 k = rg % 2;
                    uint8 mask = uint8(1 + (rg >> 1) % 15);
                    uint256[4] memory et;
                    for (uint256 i; i < 4; ++i) {
                        et[i] = _entryTick(_r(rg, i), t.buy, sTick[k][i]);
                    }
                    groups = bytes.concat(groups, OloOps.slotGroup(fm[k], 0, mask, et));
                    for (uint256 i; i < 4; ++i) {
                        if ((mask >> i) & 1 == 0) continue;
                        if (sBid[k][i] == t.buy) continue; // on the taker's own side
                        if (sOpen[k][i] == 0 || _worse(t.buy, sTick[k][i], et[i])) continue;
                        if (!t.inQuote && w.base == t.amount) continue;
                        if (refused || TakeRef.budgetRefused(t)) {
                            refused = true;
                            continue;
                        }
                        if (sTick[k][i] / 900_000 < lowest) lowest = sTick[k][i] / 900_000;
                        uint256 fx = TakeRef.fill(w, t, sOpen[k][i], sQ[k][i], sTick[k][i]);
                        sOpen[k][i] -= fx;
                    }
                }
                list = bytes.concat(list, OloOps.batchList(groups));
            }
        }
        (,, uint256 qa, bool below) = TakeRef.finish(w, t);
        // taker funds: wallet
        x.mint(taker, 1 << 120);
        y.mint(taker, 1 << 245);
        uint256 params = t.inQuote ? OloOps.quoteW(t.buy, t.amount, OloOps.WALLET) : OloOps.takeW(t.buy, t.amount, 1);
        vm.prank(taker);
        try book.take(OloOps.key(fc), list, OloOps.tagW(fc, params)) returns (uint256 got, uint256 amt) {
            assertFalse(refused, "a budget past 2^126 never succeeds");
            assertTrue(!(w.count != 0 && below), "book filled where the reference says SellBelowFee");
            assertEq(got, w.base, "base as the reference");
            assertEq(amt, qa, "quote amount as the reference");
            if (t.inQuote) assertLe(amt, t.amount, "quote mode never exceeds the amount");
            else assertLe(got, t.amount, "base mode never exceeds the amount");
            // the OLO EVM contract's words after the take equal the mirror's
            for (uint256 p; p < NP; ++p) {
                uint256 bw = book.orderWord(fc, uint32(p));
                assertEq((bw >> 33) & ((1 << 30) - 1), mOpen[p], "pool open");
            }
            for (uint256 k; k < 2; ++k) {
                (uint256 bw,) = book.batchOf(fc, fm[k], 0);
                for (uint256 i; i < 4; ++i) {
                    assertEq(((bw >> (2 + 61 * i)) & ((1 << 61) - 1)) >> 31, sOpen[k][i], "sub open");
                }
            }
            okTakes++;
            if (w.count != 0) filledTakes++;
            if (w.count != 0 && t.inQuote) quoteFilled++;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == IOloBookBase.SellBelowFee.selector) {
                assertTrue(!refused && w.count != 0 && below, "SellBelowFee only where the reference says so");
                belowFeeTakes++;
            } else if (sel == IOloBookBase.AmountOverflow.selector && refused) {
                refusedTakes++;
            } else if (sel == IOloBookBase.AmountOverflow.selector) {
                // only where the sum, at the lowest decade reached, is at least 2^235: num = Q x 10^43, so S = num /
                // 10^low (the reference's whole walk sums at least what the OLO EVM contract had when it stopped)
                assertGe(lowest, 4, "no fill below the makers' floor");
                assertFalse(
                    w.num.lt(Wide.from(1 << 235).mul(10 ** lowest)), "AmountOverflow only past 2^235 at the alignment"
                );
                overflowTakes++;
            } else {
                revert(string(abi.encodePacked("unexpected revert ", err)));
            }
        }
    }

    /// The fuzz reaches what it means to: its body over fixed seeds, takes that fill, in quote mode too.
    function test_wide_reference_reaches_fills() public {
        for (uint256 s; s < 40; ++s) {
            uint256 snap = vm.snapshotState();
            testFuzz_wide_takes_match_the_reference(uint256(keccak256(abi.encode("cov", s))));
            uint256 a = okTakes;
            uint256 b = overflowTakes;
            uint256 f = filledTakes;
            uint256 q = quoteFilled;
            uint256 bf = belowFeeTakes;
            uint256 rf = refusedTakes;
            vm.revertToState(snap);
            okTakes = a;
            overflowTakes = b;
            filledTakes = f;
            quoteFilled = q;
            belowFeeTakes = bf;
            refusedTakes = rf;
        }
        emit log_named_uint("ok takes", okTakes);
        emit log_named_uint("filled takes", filledTakes);
        emit log_named_uint("quote-mode filled takes", quoteFilled);
        emit log_named_uint("AmountOverflow takes", overflowTakes);
        emit log_named_uint("SellBelowFee takes", belowFeeTakes);
        emit log_named_uint("budgets past 2^126 refused", refusedTakes);
        assertGt(filledTakes, 15);
        assertGt(quoteFilled, 5);
    }

    function _entryTick(uint256 r, bool buy, uint256 actual) internal pure returns (uint256) {
        uint256 k = r % 5;
        if (k == 0) return actual;
        if (k == 1) return buy ? PriceGrid.MAX_TICK : 1;
        if (k == 2) return actual > 3 ? actual - 3 : 1;
        if (k == 3) return actual + 3;
        return 1 + (r >> 8) % PriceGrid.MAX_TICK;
    }

    /// Every order cancelled through the wallet and the pots collected: base out to the wei, quote only roundings.
    function _leave() internal {
        for (uint256 p; p < NP; ++p) {
            uint256 w = book.orderWord(fc, uint32(p));
            if ((w >> 33) & ((1 << 60) - 1) == 0) continue;
            address owner = address(uint160(w >> 96));
            vm.prank(owner);
            book.cancel(OloOps.key(fc), OloOps.tagW(fc, OloOps.posW(uint32(p), 0x02)));
        }
        for (uint256 k; k < 2; ++k) {
            (uint256 w,) = book.batchOf(fc, fm[k], 0);
            uint8 live;
            for (uint256 i; i < 4; ++i) {
                if ((w >> (2 + 61 * i)) & ((1 << 61) - 1) != 0) live |= uint8(1 << i);
            }
            if (live == 0) continue;
            vm.prank(fm[k]);
            (bool ok, bytes memory ret) = address(book)
                .call(
                    OloOps.batchCalldata(book.manageBatchSubs.selector, fc, OloOps.maskW(OloOps.CANCEL, 0, 0x02, live))
                );
            require(ok, string(ret));
        }
        book.collectFees(address(x));
        book.collectFees(address(y));
        assertEq(x.balanceOf(address(book)), 0, "base conserved to the wei");
        // quote: only roundings stay (every outflow above would have reverted on the token's balance)
        assertLt(y.balanceOf(address(book)), 1000, "quote: roundings only");
    }
}
