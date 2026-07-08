// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice A boolean formula over claim types, evaluated in plain Solidity (no ZK) — the
///         layer-2 unit apps talk to (ARCHITECTURE_UPDATED.md §2.2). Formulas are flat
///         `allOf + anyOf` on purpose; nested trees are deferred until a partner needs one.
/// @param allOf      every listed claim type must be valid for the subject.
/// @param anyOf      at least one must be valid (empty = skipped); this is where the
///                   sybil-anchor choice lives, e.g. any `UNIQUE_HUMAN_*` provider (§5).
/// @param consumable enables one-time semantics via `consume` (claim / vote / drop).
/// @param metadataURI off-chain JSON descriptor (display name, docs).
struct Statement {
    bytes32[] allOf;
    bytes32[] anyOf;
    bool consumable;
    string metadataURI;
}

/// @notice What every consuming app (event gate, pool, forum, DAO) integrates against —
///         one interface, not N provider SDKs.
interface IStatementRegistry {
    // -- governance --
    function registerStatement(bytes32 statementId, Statement calldata s) external;

    /// @notice The stored formula for a statement (allOf/anyOf/consumable/metadataURI).
    function getStatement(bytes32 statementId) external view returns (Statement memory);

    /// @notice Pure eligibility (view) — forums, token-gates, UIs.
    function check(bytes32 subject, bytes32 statementId) external view returns (bool);

    /// @notice Eligibility + one-time consumption, scoped per (app = msg.sender, contextId).
    ///         `contextId` = poolId / proposalId / epoch — repeated actions are a parameter,
    ///         not a redesign.
    function consume(bytes32 subject, bytes32 statementId, uint256 contextId) external;

    /// @notice Whether `subject` already consumed `statementId` for a given app + context.
    function isConsumed(bytes32 statementId, address app, uint256 contextId, bytes32 subject)
        external
        view
        returns (bool);
}
