// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IStatementRegistry} from "../interfaces/IStatementRegistry.sol";

/// @title SubsidyPool
/// @notice Reference **consumer** app for the zk statements layer (ARCHITECTURE_UPDATED.md §8):
///         a funds-holding pool that pays a fixed subsidy to anyone who satisfies a statement,
///         once per epoch. Deployed by event organizers, NOT by the layer — its ENTIRE
///         integration is calling `check` (view eligibility) and `consume` (eligibility +
///         one-time action). No provider SDK, no ZK, no contact with any issuer.
///
///         The access rule is whatever the referenced `statementId` encodes (e.g. §8's
///         "attended Zuitzerland May 2025 AND over-18 AND (Rarimo OR World ID human)"). Swapping
///         the rule is a governance action on the StatementRegistry — this contract never changes.
///
/// @dev Epoch model: `contextId = block.timestamp / epochLength` (default 30 days), so the
///      statement's `consume` bookkeeping enforces "once per epoch per subject per app" — the
///      concrete form of §8's "contextId = the month". `consume` commits the consumed flag in the
///      registry BEFORE the payout transfer, so it doubles as the reentrancy guard: a reentrant
///      `claim` for the same (subject, epoch) reverts `AlreadyConsumed`.
///
/// @dev **Phase-1 trust boundary (honest):** claims are pseudonymous, not unlinkable (§4). This
///      pool trusts that the caller legitimately controls `subject` — it does not (and in Phase 1
///      cannot) cryptographically bind `subject` to `msg.sender`. That trustless binding is
///      exactly the Phase-3 upgrade (per-app nullifiers): the client proves control of a subject
///      in ZK and presents an app-scoped nullifier, at which point `subject` never appears here.
///      Until then, run claims via the frontend/relayer that issued the subject.
contract SubsidyPool is Ownable {
    IStatementRegistry public immutable statements;
    /// @dev The statement id this pool gates on (registered by the organizers on the registry).
    bytes32 public immutable statementId;
    /// @dev Length of one claim epoch in seconds (the `consume` context granularity).
    uint256 public immutable epochLength;

    /// @dev Amount paid per successful claim (owner-configurable).
    uint256 public payoutAmount;

    event Funded(address indexed from, uint256 amount);
    event PayoutAmountUpdated(uint256 amount);
    event Claimed(bytes32 indexed subject, address indexed recipient, uint256 indexed epoch, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    error InsufficientPoolBalance(uint256 balance, uint256 needed);
    error PayoutFailed();

    /// @param owner_        the organizers (pool admin: funds, payout size, withdrawals).
    /// @param statements_   the shared StatementRegistry.
    /// @param statementId_  the access rule to gate on.
    /// @param payoutAmount_ wei paid per successful claim.
    /// @param epochLength_  claim epoch in seconds (0 = default 30 days).
    constructor(
        address owner_,
        IStatementRegistry statements_,
        bytes32 statementId_,
        uint256 payoutAmount_,
        uint256 epochLength_
    ) Ownable(owner_) {
        statements = statements_;
        statementId = statementId_;
        payoutAmount = payoutAmount_;
        epochLength = epochLength_ == 0 ? 30 days : epochLength_;
    }

    // -----------------------------------------------------------------------
    // Funding / admin (organizers)
    // -----------------------------------------------------------------------
    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Top up the pool.
    function fund() external payable {
        emit Funded(msg.sender, msg.value);
    }

    function setPayoutAmount(uint256 payoutAmount_) external onlyOwner {
        payoutAmount = payoutAmount_;
        emit PayoutAmountUpdated(payoutAmount_);
    }

    /// @notice Recover unspent funds.
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        if (address(this).balance < amount) revert InsufficientPoolBalance(address(this).balance, amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayoutFailed();
        emit Withdrawn(to, amount);
    }

    // -----------------------------------------------------------------------
    // The whole integration surface: check + consume
    // -----------------------------------------------------------------------
    /// @notice Current epoch (the `consume` contextId).
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / epochLength;
    }

    /// @notice Pure eligibility (no state change) — for UIs / off-chain gating.
    function eligible(bytes32 subject) external view returns (bool) {
        return statements.check(subject, statementId);
    }

    /// @notice Whether `subject` has already claimed from THIS pool in the current epoch.
    function hasClaimedThisEpoch(bytes32 subject) external view returns (bool) {
        return statements.isConsumed(statementId, address(this), currentEpoch(), subject);
    }

    /// @notice Claim this epoch's subsidy for `subject`, paid to the caller.
    /// @dev Reverts `NotEligible` (fails the statement) or `AlreadyConsumed` (already claimed this
    ///      epoch) from the registry. Payout goes to `msg.sender`; see the Phase-1 trust boundary
    ///      note on the contract.
    function claim(bytes32 subject) external {
        uint256 epoch = currentEpoch();

        // Effect first: burns this (subject, epoch) at the registry — also the reentrancy guard.
        statements.consume(subject, statementId, epoch);

        uint256 amount = payoutAmount;
        if (address(this).balance < amount) revert InsufficientPoolBalance(address(this).balance, amount);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert PayoutFailed();

        emit Claimed(subject, msg.sender, epoch, amount);
    }
}
