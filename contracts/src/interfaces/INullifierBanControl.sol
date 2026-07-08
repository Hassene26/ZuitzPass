// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal interface a gate/registry exposes so `ZuitzerlandGovernance` can (un)ban
///         nullifiers/subjects. Implemented by `ZuitzPassExecutor`, `WorldIDGate`, and
///         `ClaimsRegistry`, so one governance contract drives them uniformly.
interface INullifierBanControl {
    function setNullifierBanned(bytes32 nullifier, bool banned) external;
}
