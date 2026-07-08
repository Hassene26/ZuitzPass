// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IStatementRegistry, Statement} from "./interfaces/IStatementRegistry.sol";
import {IClaimsRegistry} from "./interfaces/IClaimsRegistry.sol";

/// @title StatementRegistry
/// @notice Layer-2 of the zk statements layer (ARCHITECTURE_UPDATED.md §2.2): evaluates a
///         boolean formula over `ClaimsRegistry` claims in plain Solidity (a few SLOADs, no ZK).
///         This is the single interface every consuming app integrates against — event gates,
///         subsidy pools, forums, DAOs — via `check` (view eligibility) or `consume`
///         (eligibility + one-time action, scoped per app + context).
///
/// @dev Governance (owner = multisig) registers statements; apps only ever call `check`/`consume`.
///      Consumption is keyed `[statementId][msg.sender][contextId][subject]` so one app can never
///      burn another app's eligibility, and `contextId` (a month, a proposal, a pool epoch) turns
///      "once per X" into a parameter rather than a redesign (§8 Act 2).
contract StatementRegistry is IStatementRegistry, Ownable {
    IClaimsRegistry public immutable claims;

    /// @dev The registered statements by id.
    mapping(bytes32 => Statement) internal _statements;
    /// @dev Whether a statement id has been registered.
    mapping(bytes32 => bool) public statementRegistered;
    /// @dev consumed[statementId][app][contextId][subject].
    mapping(bytes32 => mapping(address => mapping(uint256 => mapping(bytes32 => bool)))) public consumed;

    event StatementRegistered(bytes32 indexed statementId, bool consumable, string metadataURI);
    event Consumed(
        bytes32 indexed statementId, address indexed app, uint256 indexed contextId, bytes32 subject
    );

    error StatementAlreadyRegistered(bytes32 statementId);
    error StatementNotRegistered(bytes32 statementId);
    error NotConsumable(bytes32 statementId);
    error NotEligible(bytes32 subject, bytes32 statementId);
    error AlreadyConsumed(bytes32 statementId, address app, uint256 contextId, bytes32 subject);

    constructor(address owner_, IClaimsRegistry claims_) Ownable(owner_) {
        claims = claims_;
    }

    // -----------------------------------------------------------------------
    // Governance
    // -----------------------------------------------------------------------
    /// @inheritdoc IStatementRegistry
    /// @dev Statements are immutable once registered (no versioning until a partner needs it —
    ///      §6 anti-scope-creep). Register a new id to change a rule.
    function registerStatement(bytes32 statementId, Statement calldata s) external override onlyOwner {
        if (statementRegistered[statementId]) revert StatementAlreadyRegistered(statementId);
        statementRegistered[statementId] = true;
        _statements[statementId] = s;
        emit StatementRegistered(statementId, s.consumable, s.metadataURI);
    }

    /// @inheritdoc IStatementRegistry
    function getStatement(bytes32 statementId) external view override returns (Statement memory) {
        return _statements[statementId];
    }

    // -----------------------------------------------------------------------
    // App-facing
    // -----------------------------------------------------------------------
    /// @inheritdoc IStatementRegistry
    function check(bytes32 subject, bytes32 statementId) public view override returns (bool) {
        if (!statementRegistered[statementId]) revert StatementNotRegistered(statementId);
        Statement storage s = _statements[statementId];

        // allOf: every listed type must be valid.
        uint256 allLen = s.allOf.length;
        for (uint256 i = 0; i < allLen; ++i) {
            if (!claims.hasValidClaim(subject, s.allOf[i])) return false;
        }

        // anyOf: at least one must be valid; empty = skipped.
        uint256 anyLen = s.anyOf.length;
        if (anyLen == 0) return true;
        for (uint256 i = 0; i < anyLen; ++i) {
            if (claims.hasValidClaim(subject, s.anyOf[i])) return true; // short-circuit
        }
        return false;
    }

    /// @inheritdoc IStatementRegistry
    function consume(bytes32 subject, bytes32 statementId, uint256 contextId) external override {
        if (!statementRegistered[statementId]) revert StatementNotRegistered(statementId);
        if (!_statements[statementId].consumable) revert NotConsumable(statementId);
        if (!check(subject, statementId)) revert NotEligible(subject, statementId);

        if (consumed[statementId][msg.sender][contextId][subject]) {
            revert AlreadyConsumed(statementId, msg.sender, contextId, subject);
        }
        consumed[statementId][msg.sender][contextId][subject] = true;
        emit Consumed(statementId, msg.sender, contextId, subject);
    }

    /// @inheritdoc IStatementRegistry
    function isConsumed(bytes32 statementId, address app, uint256 contextId, bytes32 subject)
        external
        view
        override
        returns (bool)
    {
        return consumed[statementId][app][contextId][subject];
    }
}
