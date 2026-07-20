// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHonkVerifier} from "./interfaces/IHonkVerifier.sol";
import {DKIMKeyRegistry} from "./DKIMKeyRegistry.sol";
import {VerifiedHumansTree} from "./VerifiedHumansTree.sol";

/// @title EmailEvidenceVerifier
/// @notice The signed-document evidence adapter (docs/PRIVATE_PROVABILITY_FRAMEWORK.md §B.3) —
///         the trustless (T0) replacement for the backend DKIM check. Verifies a Circuit-C proof
///         ("a DKIM-signed email from this domain whose subject carries this event token exists,
///         bound to credential commitment C"), consumes the per-email nullifier, and inserts C
///         into the source's per-event `VerifiedHumansTree` (Part A). From there the UNCHANGED
///         Part-B flow (Circuit B → RedeemIssuer) mints the opaque claim leaf.
///
/// @dev Permissionless: anyone (a relayer) may submit — the proof commits to C, so front-running
///      is useless and the submitting wallet needn't be the user's. Deliberately shaped like
///      `RedeemIssuer`: per-source config, flat nullifier set, one external verifier.
contract EmailEvidenceVerifier is Ownable {
    /// @dev Circuit-C public outputs: [keyHash0, keyHash1, eventId, emailNullifier, credCommitment].
    uint256 internal constant N_PUB = 5;

    IHonkVerifier public immutable verifier; // Circuit-C UltraHonk verifier
    DKIMKeyRegistry public immutable dkimKeys;

    struct EmailSource {
        bytes32 domain; // keccak256(lowercase sender domain), looked up in DKIMKeyRegistry
        uint256 eventIdHash; // the circuit's event_id this source accepts (WHICH event)
        VerifiedHumansTree credTree; // per-event anonymity set; this contract is its writer
        bool enabled;
    }

    mapping(bytes32 => EmailSource) public sources;
    /// @dev One credential per email, ever (framework invariant I5).
    mapping(uint256 => bool) public consumedEmailNullifier;

    event SourceRegistered(bytes32 indexed sourceId, bytes32 domain, uint256 eventIdHash, address credTree);
    event SourceEnabled(bytes32 indexed sourceId, bool enabled);
    event EvidenceAccepted(bytes32 indexed sourceId, uint256 emailNullifier, bytes32 credCommitment);

    error SourceNotEnabled(bytes32 sourceId);
    error BadPublicInputLength(uint256 got);
    error ProofInvalid();
    error UnknownDkimKey(bytes32 domain, bytes32 keyHash0, bytes32 keyHash1);
    error WrongEvent(uint256 got, uint256 expected);
    error EmailAlreadyUsed(uint256 emailNullifier);

    constructor(address owner_, IHonkVerifier verifier_, DKIMKeyRegistry dkimKeys_) Ownable(owner_) {
        verifier = verifier_;
        dkimKeys = dkimKeys_;
    }

    // -----------------------------------------------------------------------
    // Governance
    // -----------------------------------------------------------------------
    /// @notice Register an email source = one (domain, event token) pair feeding one credential
    ///         tree. The tree's writer must be set to this contract.
    function registerSource(bytes32 sourceId, bytes32 domain, uint256 eventIdHash, VerifiedHumansTree credTree)
        external
        onlyOwner
    {
        sources[sourceId] = EmailSource({domain: domain, eventIdHash: eventIdHash, credTree: credTree, enabled: true});
        emit SourceRegistered(sourceId, domain, eventIdHash, address(credTree));
    }

    function setSourceEnabled(bytes32 sourceId, bool enabled) external onlyOwner {
        sources[sourceId].enabled = enabled;
        emit SourceEnabled(sourceId, enabled);
    }

    // -----------------------------------------------------------------------
    // Evidence submission (anyone — typically the user via a relayer)
    // -----------------------------------------------------------------------
    /// @param sourceId which registered (domain, event) source the evidence targets.
    /// @param proof    the Circuit-C proof.
    /// @param pub      [keyHash0, keyHash1, eventId, emailNullifier, credCommitment].
    function submitEvidence(bytes32 sourceId, bytes calldata proof, bytes32[] calldata pub) external {
        EmailSource memory src = sources[sourceId];
        if (!src.enabled) revert SourceNotEnabled(sourceId);
        if (pub.length != N_PUB) revert BadPublicInputLength(pub.length);
        if (!verifier.verify(proof, pub)) revert ProofInvalid();

        // The signing key must be an allowed key for the source's domain (registry decides —
        // key rotation is config, not circuits).
        if (!dkimKeys.isValidKey(src.domain, pub[0], pub[1])) {
            revert UnknownDkimKey(src.domain, pub[0], pub[1]);
        }

        // Content specificity: the proof's in-circuit event token must be THIS event's.
        if (uint256(pub[2]) != src.eventIdHash) revert WrongEvent(uint256(pub[2]), src.eventIdHash);

        // One credential per email, ever.
        uint256 emailNullifier = uint256(pub[3]);
        if (consumedEmailNullifier[emailNullifier]) revert EmailAlreadyUsed(emailNullifier);
        consumedEmailNullifier[emailNullifier] = true;

        // Part A: the bound credential joins the per-event anonymity set.
        src.credTree.insertCredential(pub[4]);

        emit EvidenceAccepted(sourceId, emailNullifier, pub[4]);
    }
}
