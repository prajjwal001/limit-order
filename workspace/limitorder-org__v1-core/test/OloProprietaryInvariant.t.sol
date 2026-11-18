// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {OloBook} from "../src/OloBook.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {RolePolicy} from "./OloProprietary.t.sol";

/// Four actors in a proprietary market whose policy the handler changes at random (each actor may make, take, both or
/// neither), placing, modifying, posting batches, taking, cancelling, claiming and withdrawing. It records every call
/// the OLO EVM contract let through that the policy did not admit at that moment, and every exit (a cancel, a claim, a
/// batch cancel, a withdrawal) the OLO EVM contract refused as NotAdmitted.
contract ProprietaryHandler is Test {
    uint256 constant T = 34_200_000;
    uint256 constant LOT = 1e6;

    OloBook public book;
    RolePolicy public policy;
    MockERC20 public base;
    MockERC20 public quote;
    MarketWord public pk;
    MarketWord public pc;
    address[4] public actors;

    struct Order {
        address owner;
        uint32 pos;
        bool isBid;
    }

    Order[] internal orders;
    uint32 internal nextPos = 1;
    mapping(address => bool) internal posted; // a batch slot 0 posted and not cancelled

    // what the policy should have stopped and what the OLO EVM contract should never stop
    uint256 public unadmittedPassed;
    uint256 public exitRefused;
    // reach
    uint256 public placesOk;
    uint256 public placesRefused;
    uint256 public takesOk;
    uint256 public takesRefused;
    uint256 public modifiesRefused;
    uint256 public batchPostsOk;
    uint256 public batchPostsRefused;
    uint256 public exitsOk;
    uint256 public exitsByRevoked;

    constructor(OloBook book_, RolePolicy policy_, MockERC20 base_, MockERC20 quote_, MarketWord pc_) {
        book = book_;
        policy = policy_;
        base = base_;
        quote = quote_;
        pc = pc_;
        pk = OloOps.key(pc_);
        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0xA000 + i));
            actors[i] = a;
            base.mint(a, 1e30);
            quote.mint(a, 1e30);
            vm.startPrank(a);
            base.approve(address(book), type(uint256).max);
            quote.approve(address(book), type(uint256).max);
            book.deposit(address(base), 1e24);
            book.deposit(address(quote), 1e24);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function _isRefused(bytes memory err) internal pure returns (bool) {
        return err.length >= 4 && bytes4(err) == IOloBookBase.NotAdmitted.selector;
    }

    /// The policy changes its mind about one actor.
    function setRoles(uint256 who, bool canMake, bool canTake) external {
        policy.set(_actor(who), canMake, canTake);
    }

    function place(uint256 who, uint256 tickSeed, bool isBid, uint256 amountSeed) external {
        address a = _actor(who);
        bool admitted = policy.maker(a);
        uint256 tick = isBid ? T - 1 - tickSeed % 8 : T + 1 + tickSeed % 8;
        uint256 amount = (1 + amountSeed % 20) * LOT;
        uint32 pos = nextPos++;
        vm.prank(a);
        try book.place(pk, OloOps.placeW(isBid, tick, amount, pos, 0)) {
            if (!admitted) ++unadmittedPassed;
            orders.push(Order(a, pos, isBid));
            ++placesOk;
        } catch (bytes memory err) {
            if (_isRefused(err)) {
                if (admitted) ++unadmittedPassed; // refused one the policy admits: counted as a wrong answer too
                ++placesRefused;
            }
        }
    }

    function modify(uint256 orderSeed, uint256 tickSeed) external {
        if (orders.length == 0) return;
        Order memory o = orders[orderSeed % orders.length];
        bool admitted = policy.maker(o.owner);
        uint256 tick = o.isBid ? T - 1 - tickSeed % 8 : T + 1 + tickSeed % 8;
        vm.prank(o.owner);
        try book.modify(pk, OloOps.tagW(pc, OloOps.modifyW(o.pos, tick, LOT, 0))) {
            if (!admitted) ++unadmittedPassed;
        } catch (bytes memory err) {
            if (_isRefused(err)) {
                if (admitted) ++unadmittedPassed;
                ++modifiesRefused;
            }
        }
    }

    function batchPost(uint256 who, bool isBid) external {
        address a = _actor(who);
        if (posted[a]) return;
        bool admitted = policy.maker(a);
        uint256[3] memory w = OloOps.postW(isBid, 0, isBid ? T - 2 : T + 2, LOT, 2);
        bytes memory data = OloOps.batchCalldata(book.manageBatchSubs.selector, pc, w);
        vm.prank(a);
        (bool ok, bytes memory err) = address(book).call(data);
        if (ok) {
            if (!admitted) ++unadmittedPassed;
            posted[a] = true;
            ++batchPostsOk;
        } else if (_isRefused(err)) {
            if (admitted) ++unadmittedPassed;
            ++batchPostsRefused;
        }
    }

    function take(uint256 who, uint256 orderSeed, uint256 amountSeed) external {
        if (orders.length == 0) return;
        address a = _actor(who);
        bool admitted = policy.taker(a);
        Order memory o = orders[orderSeed % orders.length];
        (uint256 tick, uint256 open,,,) = book.orderOf(pc, o.pos);
        if (open == 0) return;
        uint256 amount = 1 + amountSeed % open;
        bytes memory list = OloOps.poolList(OloOps.poolEntry(o.pos, tick));
        vm.prank(a);
        try book.take(pk, list, OloOps.tagW(pc, OloOps.takeW(!o.isBid, amount, 0))) {
            if (!admitted) ++unadmittedPassed;
            ++takesOk;
        } catch (bytes memory err) {
            if (_isRefused(err)) {
                if (admitted) ++unadmittedPassed;
                ++takesRefused;
            }
        }
    }

    /// An exit: never NotAdmitted, whatever the policy says of its caller.
    function _exit(address a, bytes memory data) internal {
        bool revoked = !policy.maker(a);
        vm.prank(a);
        (bool ok, bytes memory err) = address(book).call(data);
        if (ok) {
            ++exitsOk;
            if (revoked) ++exitsByRevoked;
        } else if (_isRefused(err)) {
            ++exitRefused;
        }
    }

    function cancel(uint256 orderSeed) external {
        if (orders.length == 0) return;
        uint256 i = orderSeed % orders.length;
        Order memory o = orders[i];
        _exit(o.owner, abi.encodeCall(book.cancel, (pk, OloOps.tagW(pc, OloOps.posW(o.pos, 0)))));
        orders[i] = orders[orders.length - 1];
        orders.pop();
    }

    function claim(uint256 orderSeed) external {
        if (orders.length == 0) return;
        Order memory o = orders[orderSeed % orders.length];
        _exit(o.owner, abi.encodeCall(book.claim, (pk, OloOps.tagW(pc, OloOps.posW(o.pos, 0)))));
    }

    function batchCancel(uint256 who) external {
        address a = _actor(who);
        if (!posted[a]) return;
        _exit(a, OloOps.batchCalldata(book.manageBatchSubs.selector, pc, OloOps.maskW(OloOps.CANCEL, 0, 0, 0x3)));
        posted[a] = false;
    }

    function withdraw(uint256 who, bool inBase, uint256 part) external {
        address a = _actor(who);
        MockERC20 token = inBase ? base : quote;
        uint256 held = book.balanceOf(book.tokenId(address(token)), a);
        if (held == 0) return;
        uint256 amount = 1 + part % held;
        bool revoked = !policy.maker(a) && !policy.taker(a);
        vm.prank(a);
        try book.withdraw(address(token), amount) {
            ++exitsOk;
            if (revoked) ++exitsByRevoked;
        } catch {
            ++exitRefused; // a withdrawal of what an account holds never fails
        }
    }
}

/// The handler's invariants: the OLO EVM contract lets through only what the policy admits, refuses no exit, and holds
/// what it owes.
contract OloProprietaryInvariantTest is OloBase {
    ProprietaryHandler handler;
    RolePolicy policy;

    function setUp() public {
        _deploy();
        policy = new RolePolicy();
        book.setProprietaryListingAllowed(address(this), true);
        uint32 pm = book.listMarketQuoteProprietary(address(base), address(quote), 50, 6, 1, 0, address(policy));
        handler = new ProprietaryHandler(book, policy, base, quote, book.configOf(pm));
        targetContract(address(handler));
    }

    function invariant_only_the_admitted_trade() public view {
        assertEq(handler.unadmittedPassed(), 0, "a call the policy did not admit went through, or the reverse");
    }

    function invariant_no_exit_is_refused() public view {
        assertEq(handler.exitRefused(), 0, "an exit refused");
    }

    /// The OLO EVM contract holds at least what the actors' accounts and the fee pot say it owes; resting orders'
    /// escrow is on top.
    function invariant_solvent() public view {
        MockERC20[2] memory tokens = [base, quote];
        for (uint256 t; t < 2; ++t) {
            uint256 id = book.tokenId(address(tokens[t]));
            uint256 owed = book.balanceOf(id, address(0));
            for (uint256 i; i < 4; ++i) {
                owed += book.balanceOf(id, handler.actors(i));
            }
            assertGe(tokens[t].balanceOf(address(book)), owed, "solvent");
        }
    }

    /// The handler reaches what the invariants watch: places, takes and batch posts admitted and refused, modifies
    /// refused, exits, and exits by an actor the policy no longer admits. Driven here with fixed seeds.
    function test_handler_reaches_everything() public {
        uint256 r = 1;
        for (uint256 step; step < 600; ++step) {
            r = uint256(keccak256(abi.encode(r, step)));
            uint256 op = r % 9;
            uint256 s1 = r >> 8;
            uint256 s2 = r >> 64;
            if (op == 0) handler.setRoles(s1, s2 & 1 != 0, s2 & 2 != 0);
            else if (op == 1 || op == 2) handler.place(s1, s2, s2 & 4 != 0, s2 >> 8);
            else if (op == 3) handler.modify(s1, s2);
            else if (op == 4) handler.batchPost(s1, s2 & 1 != 0);
            else if (op == 5) handler.take(s1, s2, s2 >> 8);
            else if (op == 6) handler.cancel(s1);
            else if (op == 7) handler.claim(s1);
            else if (s2 & 1 != 0) handler.batchCancel(s1);
            else handler.withdraw(s1, s2 & 2 != 0, s2 >> 8);
        }
        assertEq(handler.unadmittedPassed(), 0);
        assertEq(handler.exitRefused(), 0);
        assertGt(handler.placesOk(), 0, "places");
        assertGt(handler.placesRefused(), 0, "places refused");
        assertGt(handler.takesOk(), 0, "takes");
        assertGt(handler.takesRefused(), 0, "takes refused");
        assertGt(handler.modifiesRefused(), 0, "modifies refused");
        assertGt(handler.batchPostsOk(), 0, "batch posts");
        assertGt(handler.batchPostsRefused(), 0, "batch posts refused");
        assertGt(handler.exitsOk(), 0, "exits");
        assertGt(handler.exitsByRevoked(), 0, "exits by a revoked actor");
    }
}
