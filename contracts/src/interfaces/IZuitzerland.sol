// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice ERC-7812 EvidenceRegistry (singleton) — only the bit we need.
interface IEvidenceRegistry {
    /// @return The block timestamp at which `root` was registered (0 if unknown).
    function getRootTimestamp(bytes32 root) external view returns (uint256);
}

/// @notice The Noir-exported Solidity verifier. Treated as a black box.
/// @dev Public inputs are passed in the LOCKED order: [root, nullifier, sessionBinding].
interface INoirVerifier {
    function verifyProof(bytes calldata proof, bytes32[] calldata publicInputs)
        external
        view
        returns (bool);
}

/// @notice Per-provider policy holder. ERC-7812 is a SINGLE shared registry, so the
///         adapter no longer routes to a registry — it carries the provider-specific
///         data the verifier needs:
///           - `registrar`: the provider's ERC-7812 registrar address. Statements are
///             stored in the global SMT at `getIsolatedKey(registrar, key)`, so the
///             registrar identifies which provider a membership came from. It is bound
///             into the proof as a public input.
///           - `rootValidityWindow`: how long a global root stays acceptable when this
///             provider's credential is presented (e.g. zkPassport months, Rarimo a week).
interface IProviderAdapter {
    function registrar() external view returns (address);
    function rootValidityWindow() external view returns (uint256);
}

/// @notice One proof from one provider.
struct ProofSubmission {
    bytes proof;
    bytes32 root;
    bytes32 nullifier;
    bytes32 sessionBinding;
    address provider; // which registered adapter validates the root
}
