// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {SettleFlags} from "../src/libraries/Flags.sol";

/// The ledger and the account flow of OloBookAssets in plain Solidity, for reading beside the assembly and for the
/// differential fuzz (OloLedgerRef.t.sol) to hold the OLO EVM contract to: `addMaker` is `_ledgerFlows` (a multicall
/// op's flow), `addToken` is `_ledgerAdd`, `commit` is `_commit` with `_moveAccount` inside it. A single operation with
/// settle flags settles as a one-entry ledger committed with them would (`_settleFlows`: credits, then pulls, then
/// pushes); without flags it is `moveAccount` alone.
library LedgerRef {
    uint256 internal constant TOKENS = 4;
    uint256 internal constant AMOUNT_MASK = (1 << 128) - 1;

    /// One account's flows: `key` the token id; `maker` the orders' net flow (escrows negative, refunds and proceeds
    /// positive); `credit` the account's own flow (a DEPOSIT +, a WITHDRAW -); `wallet` the wallet's (a DEPOSIT -,
    /// a WITHDRAW +).
    struct Flow {
        uint256 key;
        int256 maker;
        int256 credit;
        int256 wallet;
    }

    struct Ledger {
        uint256 n;
        Flow[TOKENS] entries;
    }

    /// The entry of `key`, found among the `n` in use or added after them; `full` when a fifth account is asked for
    /// (the contract's TooManyTokens).
    function entryOf(Ledger memory l, uint256 key) internal pure returns (Flow memory e, bool full) {
        for (uint256 i; i < l.n; ++i) {
            if (l.entries[i].key == key) return (l.entries[i], false);
        }
        if (l.n == TOKENS) return (e, true);
        e = l.entries[l.n];
        e.key = key;
        l.n += 1;
    }

    /// An order's flow on account `key` in a multicall (`_ledgerFlows`).
    function addMaker(Ledger memory l, uint256 key, int256 flow) internal pure returns (bool full) {
        Flow memory e;
        (e, full) = entryOf(l, key);
        if (!full) e.maker += flow;
    }

    /// A DEPOSIT's or a WITHDRAW's flows on account `key` (`_ledgerAdd`).
    function addToken(Ledger memory l, uint256 key, int256 credit, int256 wallet) internal pure returns (bool full) {
        Flow memory e;
        (e, full) = entryOf(l, key);
        if (!full) {
            e.credit += credit;
            e.wallet += wallet;
        }
    }

    /// `flow` on the account whose balance is `balances[key]`, now: the error the contract reverts with, or 0.
    function moveAccount(uint256[] memory balances, uint256 key, int256 flow) internal pure returns (bytes4) {
        if (flow < 0) {
            uint256 amount = uint256(-flow);
            if (balances[key] < amount) return IOloBookBase.InsufficientBalance.selector;
            balances[key] -= amount;
        } else {
            uint256 balance = balances[key] + uint256(flow);
            if (balance > AMOUNT_MASK) return IOloBookBase.AmountOverflow.selector;
            balances[key] = balance;
        }
        return 0;
    }

    /// The balance once `credit` (signed) is applied, floored at zero (`_creditAfter`).
    function creditAfter(uint256 balance, int256 credit) internal pure returns (uint256) {
        if (credit >= 0) return balance + uint256(credit);
        uint256 out = uint256(-credit);
        return balance > out ? balance - out : 0;
    }

    /// Settles the ledger by the settle `flags` (`_commit`): per entry in order, the maker's flow goes to the account,
    /// or with WALLET to the wallet (AUTO takes a debit from the account first, the rest from the wallet); then the
    /// account moves by its credit and the wallet by its flow (`walletDelta[key]`, negative a pull, positive a push).
    /// Returns the first error the contract would revert with, or 0; `balances` and `walletDelta` are updated in place
    /// (only meaningful when 0 is returned).
    function commit(Ledger memory l, uint256 flags, uint256[] memory balances, int256[] memory walletDelta)
        internal
        pure
        returns (bytes4)
    {
        bool toWallet = flags & SettleFlags.WALLET != 0;
        bool auto_ = flags & SettleFlags.AUTO != 0;
        for (uint256 i; i < l.n; ++i) {
            Flow memory e = l.entries[i];
            int256 credit = e.credit;
            int256 wallet = e.wallet;
            if (e.maker > 0) {
                if (toWallet) wallet += e.maker;
                else credit += e.maker;
            } else if (e.maker < 0) {
                uint256 need = uint256(-e.maker);
                if (auto_) {
                    uint256 fromCredit = creditAfter(balances[e.key], credit);
                    if (fromCredit > need) fromCredit = need;
                    credit -= int256(fromCredit);
                    wallet -= int256(need - fromCredit);
                } else if (toWallet) {
                    wallet += e.maker;
                } else {
                    credit += e.maker;
                }
            }
            if (credit != 0) {
                bytes4 err = moveAccount(balances, e.key, credit);
                if (err != 0) return err;
            }
            walletDelta[e.key] += wallet;
        }
        return 0;
    }
}
