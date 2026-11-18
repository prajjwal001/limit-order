// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

/// @title The owner of an OloBook, every owner call behind a delay
/// @notice The sentinel owns the OLO EVM contract, so each of the OLO EVM contract's owner calls is an op scheduled
/// here: the exact calldata the OLO EVM contract (or, for the sentinel's own settings, the sentinel) receives. An op
/// runs only after the delay, so everyone sees it, in full in its `Scheduled` event, a delay before it can take effect.
///
/// The flow: the admin schedules an op; its eta is the time it is scheduled plus the delay then; from the eta to the
/// eta plus GRACE (7 days) the admin may execute it; after that it has expired and runs never. The admin may cancel any
/// op, one a former admin scheduled too; the guardian may cancel any op but a guardian change, so a guardian gone wrong
/// can be replaced and cannot hold its own replacement off.
///
/// Every op has a key: the setting it changes, as its setter's selector and the object it names (a market's id; a pair
/// of tokens, in the OLO EVM contract's order; a lister, for its right to list proprietary markets; none for a global
/// setting). A key has at most one op scheduled at a time: another is refused (KeyPending) until that one has run, been
/// cancelled or expired. With the OLO EVM contract's own step (a fee moves at most 1% a call, MAX_FEE_STEP_PPM) a
/// market's fee and the global fee floor each move at most 1% a delay. A market's fee and its share are two keys, so
/// both may change in one transaction: send the share first and the fee second (IOloBookExt.setMarketFee). What a
/// pair's next listing meets (the pair's own floor, else the global one) is fed by two keys, so it can move 2% in one
/// transaction: the global floor then the pair's first floor, or a lift then the global floor. From an own floor 1%
/// under (or over) the global one two such moves follow each other a delay apart: 4% in two runs. Over n runs of each
/// key it moves at most (n + 2)%, and (n + 1)% from a pair with no floor of its own. Listings only: no market's fee
/// moves (accepted).
///
/// Ops are checked when they run, by the OLO EVM contract: scheduling only decodes an op, strictly (its selector one of
/// the thirteen below, its arguments each in their type's range, its length exactly theirs), so one value of one
/// setting has one encoding, but for a pair's ops, whose two token orders both decode (to one key). The OLO EVM
/// contract's owner ops, sent to the OLO EVM contract: IOloBookExt.setMarketFee, setMarketMakerShare,
/// setGlobalFeeFloor, setGlobalMakerShare, setPairFeeFloor, setPairMakerShare, setCurrentListingFee, setFeeRecipient,
/// setProprietaryListingAllowed, and IOwned2Step.transferOwnership. The sentinel's own, sent to itself: setDelay,
/// setGuardian, transferAdmin.
interface IOloSentinel {
    /// @notice An op scheduled: its key, the time from which it may run, and the op in full.
    event Scheduled(bytes32 indexed key, uint256 eta, bytes op);
    /// @notice An op run.
    event Executed(bytes32 indexed key, bytes op);
    /// @notice An op cancelled, by the admin or the guardian.
    event Cancelled(bytes32 indexed key, address indexed by);
    /// @notice The delay set: at the deployment, or by a `setDelay` op.
    event DelaySet(uint256 delay);
    /// @notice The guardian set (zero: none): at the deployment, or by a `setGuardian` op.
    event GuardianSet(address indexed guardian);
    /// @notice An admin proposed (zero: the proposal withdrawn) by a `transferAdmin` op; it takes over by
    /// `acceptAdmin`.
    event AdminProposed(address indexed pending);
    /// @notice The admin set: at the deployment, or by `acceptAdmin`.
    event AdminSet(address indexed admin);

    /// @notice The caller is not the admin.
    error NotAdmin();
    /// @notice The caller may not cancel: neither the admin nor the guardian, or the guardian and the op a guardian
    /// change.
    error NotCanceller();
    /// @notice The caller is not the proposed admin.
    error NotPendingAdmin();
    /// @notice A setting of the sentinel's own called but by an op.
    error NotSelf();
    /// @notice An op whose selector is not one the sentinel schedules.
    error UnknownOp(bytes4 selector);
    /// @notice An op whose arguments do not decode exactly: a length not theirs, or a value out of its type's range.
    error MalformedOp();
    /// @notice An op scheduled for the key already, not run, cancelled or expired.
    error KeyPending(bytes32 key);
    /// @notice No such op scheduled for the key (none, another op, or one expired).
    error NotScheduled(bytes32 key);
    /// @notice The op's eta has not come.
    error NotReady(bytes32 key, uint256 eta);
    /// @notice The op's eta plus GRACE has passed.
    error Expired(bytes32 key, uint256 eta);
    /// @notice A delay out of [MIN_DELAY, MAX_DELAY].
    error BadDelay();
    /// @notice A zero OLO EVM contract or admin at the deployment.
    error ZeroAddress();
    /// @notice The sentinel does not own the OLO EVM contract: it schedules nothing until it has accepted it.
    error NotBookOwner();

    /// @notice Admin only, and only while the sentinel owns the OLO EVM contract (NotBookOwner). Schedules `ops`, each
    /// to run from now plus the delay, each under its own key (KeyPending when an op is scheduled for one already;
    /// UnknownOp or MalformedOp when one does not decode). An op runs only in the stretch of ownership it was scheduled
    /// in: a stretch begins when the sentinel takes the OLO EVM contract over from another owner (`acceptBookOwnership`),
    /// and an op scheduled at an earlier time (the block's timestamp, in seconds) is stale (it neither runs nor holds its
    /// key). So no sentinel holds ops for a handover's transaction, its successor's or its own from an earlier
    /// stretch: each op waits a delay within the stretch, and a chain of sentinels moves a setting as one does.
    /// @param ops The ops, each the calldata its target receives
    /// @return eta The time from which they may run
    function schedule(bytes[] calldata ops) external returns (uint256 eta);

    /// @notice Admin only. Runs `ops` in order, each scheduled exactly so in the sentinel's last stretch of ownership
    /// (NotScheduled), its eta come (NotReady) and not passed by GRACE (Expired). An op's revert is the call's, as its
    /// target gave it: nothing runs, and every op stays scheduled. Once the sentinel has handed the OLO EVM contract on,
    /// an op to the OLO EVM contract reverts there (NotOwner), while one of the sentinel's own settings still runs.
    /// @param ops The ops, as scheduled
    function execute(bytes[] calldata ops) external;

    /// @notice The admin, or the guardian for any key but a guardian change's (NotCanceller), cancels the op scheduled
    /// for each of `keys` (NotScheduled when none is, or it expired or is stale).
    /// @param keys The ops' keys (`keyOf`)
    function cancel(bytes32[] calldata keys) external;

    /// @notice Anyone. Takes the OLO EVM contract's ownership once its owner has proposed the sentinel (the OLO EVM
    /// contract's second step). Taking it over from another owner begins a new stretch of ownership: every op scheduled
    /// before is stale. Accepting the sentinel's proposal of itself (a `transferOwnership` op naming it) begins none:
    /// the sentinel held the OLO EVM contract throughout, and its ops stay as they were.
    function acceptBookOwnership() external;

    /// @notice The proposed admin takes over (NotPendingAdmin for anyone else), at any time after the `transferAdmin`
    /// op that proposed it has run: a proposal does not expire.
    function acceptAdmin() external;

    /// @notice An op only (NotSelf). Sets the delay for ops scheduled from then on; ops scheduled before keep their
    /// eta. It runs after the delay before it, like any op.
    /// @param newDelay The delay, in seconds, MIN_DELAY to MAX_DELAY (BadDelay)
    function setDelay(uint256 newDelay) external;

    /// @notice An op only (NotSelf). Sets the guardian; zero: none. The guardian cannot cancel this op.
    /// @param newGuardian The guardian
    function setGuardian(address newGuardian) external;

    /// @notice An op only (NotSelf). Proposes an admin, who takes over by `acceptAdmin`; zero withdraws a proposal.
    /// The proposed admin may accept at any later time, until another `transferAdmin` op replaces or withdraws the
    /// proposal (an op like any other: a delay ahead, and the guardian may cancel it), so propose an address about to
    /// accept and watch `pendingAdmin`.
    /// @param newAdmin The admin proposed
    function transferAdmin(address newAdmin) external;

    /// @notice The key of `op`: keccak256 of its selector and the object it names, a market's id, a pair's tokens in
    /// the OLO EVM contract's order (the lower address first), a lister (setProprietaryListingAllowed: an allow and a
    /// stop share it) or nothing. UnknownOp or MalformedOp when it does not decode.
    /// @param op An op
    /// @return key Its key
    function keyOf(bytes calldata op) external pure returns (bytes32 key);

    /// @notice The op last scheduled for `key`: the hash of its calldata and its eta, (0, 0) once it has run or been
    /// cancelled, and for an op scheduled before the sentinel's last stretch of ownership began (stale). It may run
    /// while now is in [eta, eta + GRACE]; past that it has expired.
    /// @param key The key
    /// @return opHash keccak256 of the op
    /// @return eta The time from which it may run
    function pending(bytes32 key) external view returns (bytes32 opHash, uint64 eta);

    /// @notice The OLO EVM contract the sentinel owns, fixed at the deployment.
    function book() external view returns (address);

    /// @notice The admin: schedules, executes and cancels.
    function admin() external view returns (address);

    /// @notice The admin proposed, zero when none.
    function pendingAdmin() external view returns (address);

    /// @notice The guardian: cancels any op but a guardian change. Zero: none.
    function guardian() external view returns (address);

    /// @notice The delay ops scheduled now wait, in seconds.
    function delay() external view returns (uint256);

    /// @notice The least delay, 1 day: a fee moves at most 1% a day whatever the delay.
    function MIN_DELAY() external view returns (uint256);

    /// @notice The most delay, 30 days.
    function MAX_DELAY() external view returns (uint256);

    /// @notice How long after its eta an op may still run, 7 days.
    function GRACE() external view returns (uint256);
}
