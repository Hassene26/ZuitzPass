// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {INoirVerifier} from "./interfaces/IZuitzerland.sol";

/// @notice The real Barretenberg-exported UltraHonk verifier (Circuit 1's
///         `Verifier.sol`). Its function is `verify`, not `verifyProof`.
/// @dev BB's HonkVerifier exposes:
///        function verify(bytes calldata proof, bytes32[] calldata publicInputs)
///            external view returns (bool);
interface IHonkVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs)
        external
        view
        returns (bool);
}

/// @title NoirVerifierWrapper
/// @notice Adapts the real UltraHonk verifier to the `INoirVerifier` interface
///         that `ZuitzerlandVerifier` expects.
///
/// @dev Why this exists: `ZuitzerlandVerifier` calls
///      `verifyProof(bytes, bytes32[])`, but the BB-generated verifier names the
///      function `verify(bytes, bytes32[])`. This thin shim translates the call so
///      nothing in `ZuitzerlandVerifier` needs to change. If the public-input
///      layout grows later (e.g. adding `actionId`), only this wrapper and the
///      circuit move together.
contract NoirVerifierWrapper is INoirVerifier {
    IHonkVerifier public immutable honkVerifier;

    /// @param _honkVerifier Address of the BB-exported `Verifier.sol` (HonkVerifier).
    constructor(address _honkVerifier) {
        honkVerifier = IHonkVerifier(_honkVerifier);
    }

    /// @inheritdoc INoirVerifier
    /// @dev Public inputs arrive in the LOCKED order [root, nullifier, sessionBinding].
    function verifyProof(bytes calldata proof, bytes32[] calldata publicInputs)
        external
        view
        returns (bool)
    {
        return honkVerifier.verify(proof, publicInputs);
    }
}
