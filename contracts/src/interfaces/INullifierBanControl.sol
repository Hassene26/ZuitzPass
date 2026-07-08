// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal interface a gate exposes so `ZuitzerlandGovernance` can (un)ban nullifiers.
///         Implemented by both `ZuitzerlandVerifier` (generic/Path B) and `ZuitzPassExecutor`
///         (Rarimo/Path A), so one governance contract drives either gate.
interface INullifierBanControl {
    function setNullifierBanned(bytes32 nullifier, bool banned) external;
}
