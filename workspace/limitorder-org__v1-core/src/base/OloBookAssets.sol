// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {OloBookStorage} from "./OloBookStorage.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {SafeTransfer} from "../libraries/SafeTransfer.sol";
import {SettleFlags} from "../libraries/Flags.sol";
import {MarketLib} from "../types/Market.sol";
import {MarketWord} from "../interfaces/MarketWord.sol";
import {AccountLib, OloSlots} from "../OloTypes.sol";

using MarketLib for MarketWord;

/// @title OloBookAssets
/// @notice The OLO EVM contract's balances: deposits and withdrawals, the account primitives (`_credit`, `_debit`), a
/// single operation's flows settled by its flags (`_settleFlows`), escrow funding, the taker's settlement, the fee
/// split and the pot, token transfers, and the ledger a multicall settles once at the end.
abstract contract OloBookAssets is OloBookStorage {
    // ------------------------------------------------------------------- money

    /// @notice A token a listing registered, and an amount from 1 to 2^128 - 1: only listings add tokens, so deposits
    /// cannot fill the token registry, and no owner's account holds more than 2^128 - 1 (an amount above it is refused
    /// before the pull). The fee pot holds more (`_creditPot`).
    function _deposit(address token, uint256 amount) internal {
        uint256 id = tokenId[token];
        if (id == 0) revert UnknownToken();
        if (amount == 0) revert ZeroSize();
        if (amount > AccountLib.AMOUNT_MASK) revert AmountOverflow();
        _pull(token, msg.sender, amount);
        _credit(id, amount);
        emit Deposit(msg.sender, token, amount);
    }

    function _withdraw(address token, uint256 amount, address to) internal {
        uint256 id = tokenId[token];
        if (id == 0) revert UnknownToken();
        _debit(id, amount);
        _push(token, to, amount);
        emit Withdraw(msg.sender, token, to, amount);
    }

    /// @notice Moves `flow` (signed) on the caller's account `key` now: a debit by `_debit`, a credit by `_credit`.
    function _moveAccount(uint256 key, int256 flow) internal {
        if (flow > 0) _credit(key, uint256(flow));
        else if (flow < 0) _debit(key, uint256(-flow));
    }

    /// @notice Adds `amount` to the caller's account `key` now (stored under the caller's own key, OloSlots.ownedKey):
    /// the balance must stay within 2^128 - 1 (AmountOverflow), and the word is written with USED (nonzero at a zero
    /// balance, so later credits rewrite it).
    function _credit(uint256 key, uint256 amount) internal {
        uint256 ownedKey = OloSlots.ownedKey(key, msg.sender);
        uint256 balance = AccountLib.amountOf(_accounts[ownedKey]) + amount;
        if (balance > AccountLib.AMOUNT_MASK) revert AmountOverflow();
        _accounts[ownedKey] = AccountLib.USED | balance;
    }

    /// @notice Takes `amount` from the caller's account `key` now: any amount above the balance is
    /// InsufficientBalance, and USED stays (the amount is within the word's low 128 bits).
    function _debit(uint256 key, uint256 amount) internal {
        uint256 ownedKey = OloSlots.ownedKey(key, msg.sender);
        uint256 acctWord = _accounts[ownedKey];
        if (AccountLib.amountOf(acctWord) < amount) revert InsufficientBalance();
        unchecked {
            _accounts[ownedKey] = acctWord - amount; // amount <= the balance, the word's low 128 bits
        }
    }

    /// @notice Settles one operation's flows (signed: a debit negative, a credit positive) on the caller's two
    /// accounts of a market (`acctKeys`): with no flags each moves the account now (`_moveAccount`); with settle
    /// `flags`, by `_settleFlow`, the quote's then the base's, and every push to the wallet after every pull from it,
    /// so the contract's balance covers the pushes whatever the tokens do in between (the rule `_commit` applies to a
    /// multicall's ledger, here for two accounts and no DEPOSIT or WITHDRAW).
    function _settleFlows(uint256 acctKeys, int256 quoteFlow, int256 baseFlow, uint256 flags) internal {
        if (flags == 0) {
            if (quoteFlow != 0) _moveAccount(_quoteKey(acctKeys), quoteFlow);
            if (baseFlow != 0) _moveAccount(_baseKey(acctKeys), baseFlow);
            return;
        }
        uint256 quoteKey = _quoteKey(acctKeys);
        uint256 baseKey = _baseKey(acctKeys);
        uint256 quotePush = _settleFlow(quoteKey, quoteFlow, flags);
        uint256 basePush = _settleFlow(baseKey, baseFlow, flags);
        if (quotePush != 0) _push(tokenAddr[quoteKey], msg.sender, quotePush);
        if (basePush != 0) _push(tokenAddr[baseKey], msg.sender, basePush);
    }

    /// @notice Settles `flow` (signed) of the caller's token `key` by the settle `flags`: a credit goes to the account,
    /// or with WALLET is returned for the caller to push once every pull is made; a debit is funded by `_fund`; a zero
    /// flow moves nothing.
    function _settleFlow(uint256 key, int256 flow, uint256 flags) internal returns (uint256 toPush) {
        if (flow > 0) {
            if (flags & SettleFlags.WALLET != 0) return uint256(flow);
            _moveAccount(key, flow);
        } else if (flow < 0) {
            _fund(key, uint256(-flow), flags);
        }
    }

    /// @notice Takes `amount` from the caller by the settle `flags`: AUTO from the account first and the rest from the
    /// wallet, WALLET from the wallet, neither from the account (AUTO wins over WALLET).
    function _fund(uint256 key, uint256 amount, uint256 flags) internal {
        if (flags & SettleFlags.AUTO != 0) {
            uint256 ownedKey = OloSlots.ownedKey(key, msg.sender);
            uint256 acctWord = _accounts[ownedKey];
            uint256 balance = AccountLib.amountOf(acctWord);
            if (balance >= amount) {
                unchecked {
                    _accounts[ownedKey] = acctWord - amount; // amount <= the balance, the word's low 128 bits
                }
                return;
            }
            if (balance != 0) {
                unchecked {
                    _accounts[ownedKey] = acctWord - balance; // the whole balance, the word's low 128 bits
                }
            }
            unchecked {
                amount -= balance; // balance < amount here
            }
            return _pull(tokenAddr[key], msg.sender, amount);
        }
        if (flags & SettleFlags.WALLET != 0) return _pull(tokenAddr[key], msg.sender, amount);
        _debit(key, amount);
    }

    /// @notice The taker's side: `amountIn` from `keyIn` (or the wallet), `amountOut` to `keyOut` (or the wallet).
    function _settle(uint8 settlement, uint256 keyIn, uint256 amountIn, uint256 keyOut, uint256 amountOut) internal {
        if (settlement == 0) {
            _debit(keyIn, amountIn);
            _credit(keyOut, amountOut);
            return;
        }
        _pull(tokenAddr[keyIn], msg.sender, amountIn);
        _push(tokenAddr[keyOut], msg.sender, amountOut);
    }

    /// @notice Splits the fee a settle's fills earned at the share of the version they rest in, C's makerBps (C is the
    /// version's: its orders' slots are hashed from it, so the caller's C is the one the order was placed under, and no
    /// storage is read): returns the maker's part, floored, and credits the rest to the protocol's pot of the quote
    /// token. A cancel, a claim, a modify and a batch operation that settles fills call it.
    function _splitFee(MarketWord c, uint256 fee) internal returns (uint256 makerPart) {
        uint256 makerBps = c.makerBps();
        unchecked {
            // no overflow: the fee is below 2^234 (at most the quote: an order's amount below 2^114 base wei, P at most
            // 999,999e30 < 2^120; a batch slot's four sub-orders stay below 2^236; one fill's fee can pass 2^128),
            // makerBps at most BPS: below 2^250
            makerPart = fee * makerBps / BPS;
        }
        if (makerPart != fee) _creditPot(c.quoteId(), fee - makerPart);
    }

    /// @notice The protocol's fee pot of a token: owner 0's account of it, holding up to 2^255 - 1 where an owner's
    /// account holds 2^128 - 1, so a settle whose fee is more than an account could hold is not blocked
    /// (one fill's fee can pass 10^38 at the grid's top; the pot's flows are unsigned, so the wider word is
    /// safe). The maker's own proceeds past 2^128 - 1 settle through the
    /// wallet.
    function _creditPot(uint256 id, uint256 amount) internal {
        uint256 pot = OloSlots.potKey(id);
        uint256 balance = AccountLib.potOf(_accounts[pot]) + amount;
        if (balance >> 255 != 0) revert AmountOverflow(); // past 2^255 - 1: bit 255 is USED
        _accounts[pot] = AccountLib.USED | balance;
    }

    /// @notice Transfers `amount` of `token` in from `from`, and refuses a delivery of anything but exactly `amount`
    /// (less is a fee on transfer or a rebasing token's rounding; more is refused too).
    function _pull(address token, address from, uint256 amount) internal {
        uint256 before = IERC20Minimal(token).balanceOf(address(this));
        SafeTransfer.transferFrom(token, from, address(this), amount);
        if (IERC20Minimal(token).balanceOf(address(this)) != before + amount) revert FeeOnTransfer();
    }

    /// @notice Transfers `amount` of `token` out to `to`; nothing for a zero amount.
    function _push(address token, address to, uint256 amount) internal {
        if (amount != 0) SafeTransfer.transfer(token, to, amount);
    }

    // ------------------------------------------------------------------ ledger

    /// @dev The accounts a ledger holds: a multicall touches at most four tokens.
    uint256 internal constant LEDGER_TOKENS = 4;

    /// @notice One account's flows in a ledger. `key` is the caller's account key, the token id (the owner is the
    /// caller: OloSlots.ownedKey). `maker` is the orders' net flow, signed: escrows negative, proceeds and refunds
    /// positive; `_commit` takes it from or gives it to the account or the wallet as the settle flags say. `credit` is
    /// the account's own flow: a DEPOSIT op +, a WITHDRAW op -. `wallet` is the wallet's flow: a DEPOSIT op - (pulled),
    /// a WITHDRAW op + (pushed).
    struct Flow {
        uint256 key;
        int256 maker;
        int256 credit;
        int256 wallet;
    }

    /// @notice A multicall's ledger: the flows collected per account in `entries[0 .. n - 1]` (LEDGER_TOKENS entries
    /// allocated), which `_commit` settles once each at the end of the call by the settle flags.
    struct Ledger {
        uint256 n;
        Flow[] entries;
    }

    /// @notice An empty ledger.
    function _newLedger() internal pure returns (Ledger memory ledger) {
        ledger.entries = new Flow[](LEDGER_TOKENS);
    }

    /// @notice A single operation's settle `flags`, returned once checked: bits outside SettleFlags are BadFlags.
    function _checkSettleFlags(uint256 flags) internal pure returns (uint256) {
        if (flags & ~uint256(SettleFlags.MASK) != 0) revert BadFlags();
        return flags;
    }

    /// @notice Adds an operation's flows to the ledger's entries of the caller's two accounts of a market
    /// (`acctKeys`): the quote's, then the base's, each only when it is not zero.
    function _ledgerFlows(Ledger memory ledger, uint256 acctKeys, int256 quoteFlow, int256 baseFlow) internal pure {
        if (quoteFlow != 0) _entryOf(ledger, _quoteKey(acctKeys)).maker += quoteFlow;
        if (baseFlow != 0) _entryOf(ledger, _baseKey(acctKeys)).maker += baseFlow;
    }

    /// @notice The ledger's entry of account `key`: the one in use with that key, or a new one after them; a fifth
    /// account is TooManyTokens.
    function _entryOf(Ledger memory ledger, uint256 key) internal pure returns (Flow memory entry) {
        uint256 n = ledger.n;
        for (uint256 i; i < n; ++i) {
            entry = ledger.entries[i];
            if (entry.key == key) return entry;
        }
        if (n == LEDGER_TOKENS) revert TooManyTokens();
        entry = ledger.entries[n];
        entry.key = key;
        ledger.n = n + 1;
    }

    /// @notice Adds a DEPOSIT's or a WITHDRAW's flows to the ledger's entry of account `key`: the account's `credit`
    /// and the wallet's `wallet`, each signed.
    function _ledgerAdd(Ledger memory ledger, uint256 key, int256 credit, int256 wallet) internal pure {
        Flow memory entry = _entryOf(ledger, key);
        entry.credit += credit;
        entry.wallet += wallet;
    }

    /// @notice Settles a multicall's ledger at its end. Per entry: the maker's net flow goes to the account, or with
    /// WALLET to the wallet (AUTO takes a debit from the account, as the call's own credits leave it, first and the
    /// rest from the wallet: `_settleFlow`'s rule, netted with the DEPOSIT and WITHDRAW ops); the credits are applied;
    /// and every pull from the wallet comes before any push to it, so the contract's balance covers the pushes whatever
    /// the tokens do in between.
    function _commit(Ledger memory ledger, uint256 flags) internal {
        bool toWallet = flags & SettleFlags.WALLET != 0;
        bool auto_ = flags & SettleFlags.AUTO != 0;
        uint256 n = ledger.n;
        for (uint256 i; i < n; ++i) {
            Flow memory entry = ledger.entries[i];
            uint256 key = entry.key;
            int256 makerFlow = entry.maker;
            int256 credit = entry.credit;
            int256 wallet = entry.wallet;
            unchecked {
                // every flow is far below 2^255 in magnitude (an op's escrow or proceeds below 2^235: an amount below
                // 2^114 base wei at P below 2^120, summed over a multicall's ops): no overflow here
                if (makerFlow > 0) {
                    if (toWallet) wallet += makerFlow;
                    else credit += makerFlow;
                } else if (makerFlow < 0) {
                    uint256 need = uint256(-makerFlow);
                    if (auto_) {
                        uint256 fromCredit =
                            _creditAfter(AccountLib.amountOf(_accounts[OloSlots.ownedKey(key, msg.sender)]), credit);
                        if (fromCredit > need) fromCredit = need;
                        credit -= int256(fromCredit);
                        wallet -= int256(need - fromCredit);
                    } else if (toWallet) {
                        wallet += makerFlow;
                    } else {
                        credit += makerFlow;
                    }
                }
            }
            if (credit != 0) _moveAccount(key, credit);
            if (wallet < 0) _pull(tokenAddr[key], msg.sender, uint256(-wallet));
            entry.wallet = wallet;
        }
        for (uint256 i; i < n; ++i) {
            Flow memory entry = ledger.entries[i];
            if (entry.wallet > 0) _push(tokenAddr[entry.key], msg.sender, uint256(entry.wallet));
        }
    }

    /// @notice The account's balance once the ledger's `credit` (signed) is applied, floored at zero.
    function _creditAfter(uint256 balance, int256 credit) internal pure returns (uint256) {
        if (credit >= 0) return balance + uint256(credit);
        uint256 out = uint256(-credit);
        return balance > out ? balance - out : 0;
    }
}
