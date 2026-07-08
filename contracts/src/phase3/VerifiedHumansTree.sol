// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RootedSMTRegistry} from "./RootedSMTRegistry.sol";

/// @title VerifiedHumansTree
/// @notice Per-provider anonymity-set tree for Phase-3 strong private binding (Part A of
///         contracts/PHASE3_UNLINKABLE_DESIGN.md §4). After a provider gate verifies a unique human,
///         the human inserts a **credential commitment** `C = Poseidon2(secret, r)` as a leaf
///         (`key = C, value = 1`). Later, Circuit B proves membership in this tree *without
///         revealing which `C`* to redeem the credential into a claim on their identity.
///
/// @dev A rooted SMT (see `RootedSMTRegistry`); its `writer` is the Part-A **inserter** — the
///      provider gate (or a trusted helper for the PoC). The credential leaf value is `1`, matching
///      Circuit B's `compute_cred_leaf_hash = Poseidon3(C, 1, 1)`.
contract VerifiedHumansTree is RootedSMTRegistry {
    event CredentialInserted(bytes32 indexed commitment, bytes32 newRoot);

    constructor(address owner_, uint32 maxDepth_, uint256 rootValidity_)
        RootedSMTRegistry(owner_, maxDepth_, rootValidity_)
    {}

    /// @notice Insert a verified human's credential commitment. Sybil resistance (one credential per
    ///         human) is enforced upstream by the provider gate's used-nullifier guard.
    function insertCredential(bytes32 commitment) external onlyWriter {
        emit CredentialInserted(commitment, _insertLeaf(commitment, bytes32(uint256(1))));
    }
}
