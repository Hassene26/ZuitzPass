// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    IEvidenceRegistry,
    INoirVerifier,
    IProviderAdapter,
    ProofSubmission
} from "./interfaces/IZuitzerland.sol";

/// @title ZuitzerlandVerifier
/// @notice Main entry point for the Zuitzerland gated anonymous forum.
///         Verifies ZK membership proofs (Circuit 1) and gates access by:
///           1. root recency (via the provider's ERC-7812 adapter)
///           2. nullifier not banned
///           3. nullifier not already used
///           4. proof validity (Noir-exported Solidity verifier)
///
/// @dev Public-input ordering is LOCKED by the circuit: [root, nullifier, sessionBinding].
contract ZuitzerlandVerifier is Ownable {
    // ----------------------------------------------------------------------
    // Storage
    // ----------------------------------------------------------------------
    mapping(bytes32 => bool) public usedNullifiers;
    mapping(bytes32 => bool) public bannedNullifiers;
    mapping(address => bool) public registeredAdapters;

    /// @dev ERC-7812 singleton registry (0x781246D2256dc0C1d8357c9dDc1eEe926a9c7812).
    ///      There is ONE shared registry with ONE global root for all providers; root
    ///      recency is checked here, the per-provider freshness window comes from the
    ///      adapter.
    address public evidenceRegistry;

    /// @dev The Noir-exported Solidity verifier (black box).
    INoirVerifier public noirVerifier;

    /// @dev Governance contract authorized to (un)ban nullifiers.
    address public governance;

    // ----------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------
    event ProofVerified(address indexed user, bytes32 nullifier, bytes32 sessionBinding);
    event AccessGranted(address indexed user, bytes32 sessionBinding);
    event AdapterRegistered(address indexed adapter, bool enabled);
    event GovernanceUpdated(address indexed governance);

    // ----------------------------------------------------------------------
    // Errors
    // ----------------------------------------------------------------------
    error RootExpired();
    error NullifierBanned();
    error NullifierAlreadyUsed();
    error InvalidProof();
    error SessionBindingMismatch();
    error AdapterNotRegistered();
    error NotEnoughProofs();
    error NotGovernance();

    // ----------------------------------------------------------------------
    // Construction / admin
    // ----------------------------------------------------------------------
    constructor(address _evidenceRegistry, address _noirVerifier) Ownable(msg.sender) {
        evidenceRegistry = _evidenceRegistry;
        noirVerifier = INoirVerifier(_noirVerifier);
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    function setGovernance(address _governance) external onlyOwner {
        governance = _governance;
        emit GovernanceUpdated(_governance);
    }

    function setAdapter(address adapter, bool enabled) external onlyOwner {
        registeredAdapters[adapter] = enabled;
        emit AdapterRegistered(adapter, enabled);
    }

    function setNoirVerifier(address _noirVerifier) external onlyOwner {
        noirVerifier = INoirVerifier(_noirVerifier);
    }

    function setEvidenceRegistry(address _evidenceRegistry) external onlyOwner {
        evidenceRegistry = _evidenceRegistry;
    }

    /// @notice Called by the governance contract to (un)ban a nullifier.
    function setNullifierBanned(bytes32 nullifier, bool banned) external onlyGovernance {
        bannedNullifiers[nullifier] = banned;
    }

    // ----------------------------------------------------------------------
    // Verification
    // ----------------------------------------------------------------------

    /// @notice Verify a single membership proof and grant access.
    function verify(ProofSubmission calldata submission) external {
        _verifyOne(submission);
        emit ProofVerified(msg.sender, submission.nullifier, submission.sessionBinding);
    }

    /// @notice Verify multiple proofs (e.g. Rarimo + zkPassport) bound to one session.
    /// @dev Enforces a shared sessionBinding across all proofs (anti-collusion),
    ///      then runs the 4 checks for each proof individually.
    function verifyMultiProof(ProofSubmission[] calldata proofs) external {
        if (proofs.length < 2) revert NotEnoughProofs();

        bytes32 session = proofs[0].sessionBinding;
        for (uint256 i = 0; i < proofs.length; i++) {
            if (proofs[i].sessionBinding != session) revert SessionBindingMismatch();
        }

        // Only mutate state / emit after all bindings match.
        for (uint256 i = 0; i < proofs.length; i++) {
            _verifyOne(proofs[i]);
            emit ProofVerified(msg.sender, proofs[i].nullifier, proofs[i].sessionBinding);
        }

        emit AccessGranted(msg.sender, session);
    }

    // ----------------------------------------------------------------------
    // Internal: the 4 checks, in order
    // ----------------------------------------------------------------------
    function _verifyOne(ProofSubmission calldata s) internal {
        // 0. Provider must be a registered adapter.
        if (!registeredAdapters[s.provider]) revert AdapterNotRegistered();
        IProviderAdapter adapter = IProviderAdapter(s.provider);

        // 1. Root is recent against the SINGLE shared ERC-7812 registry, using
        //    THIS provider's freshness window. getRootTimestamp returns 0 for an
        //    unknown root (per ERC-7812) and never reverts.
        uint256 ts = IEvidenceRegistry(evidenceRegistry).getRootTimestamp(s.root);
        if (ts == 0 || block.timestamp - ts > adapter.rootValidityWindow()) {
            revert RootExpired();
        }

        // 2. Nullifier is not banned.
        if (bannedNullifiers[s.nullifier]) revert NullifierBanned();

        // 3. Nullifier is not already used.
        if (usedNullifiers[s.nullifier]) revert NullifierAlreadyUsed();

        // 4. Proof is valid. Public inputs in LOCKED order:
        //    [root, nullifier, sessionBinding, registrar].
        //    The registrar is forced from the chosen adapter (NOT caller-supplied),
        //    so a proof scoped to a different provider's registrar fails here. This
        //    is what makes per-provider validity windows non-gameable: you can't
        //    claim zkPassport's longer window with a Rarimo-scoped proof.
        bytes32[] memory publicInputs = new bytes32[](4);
        publicInputs[0] = s.root;
        publicInputs[1] = s.nullifier;
        publicInputs[2] = s.sessionBinding;
        publicInputs[3] = bytes32(uint256(uint160(adapter.registrar())));
        if (!noirVerifier.verifyProof(s.proof, publicInputs)) revert InvalidProof();

        // Effects: consume the nullifier.
        usedNullifiers[s.nullifier] = true;
    }
}
