// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The shape of the Barretenberg-generated UltraHonk Solidity verifier for the eligibility
///         circuit (`bb contract`). `publicInputs` are the circuit's public inputs in declaration
///         order: [root, nullifier, app_id, context_id, now_ts, claim_types[MAX_CLAIMS], signal].
///         The generated verifier reverts or returns false on a bad proof.
interface IEligibilityVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}
