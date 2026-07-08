// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal World ID Router interface. `verifyProof` is `view` and REVERTS on an
///         invalid proof (it does not return a bool).
interface IWorldID {
    /// @param root The Merkle root of the World ID identity tree.
    /// @param groupId 1 for Orb-verified credentials.
    /// @param signalHash `hashToField(abi.encodePacked(signal))`.
    /// @param nullifierHash Per-(app, action) uniqueness handle from the proof.
    /// @param externalNullifierHash `hashToField(appId, action)`.
    /// @param proof The 8-element Groth16 proof from IDKit / the simulator.
    function verifyProof(
        uint256 root,
        uint256 groupId,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256 externalNullifierHash,
        uint256[8] calldata proof
    ) external view;
}
