// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Generic shape of a Barretenberg UltraHonk Solidity verifier (`bb contract`) — one
///         circuit per deployed verifier. `publicInputs` are the circuit's public inputs in
///         declaration order. Used by the Circuit-B redeem entrypoint (`RedeemIssuer`).
interface IHonkVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}
