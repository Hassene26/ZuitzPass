// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHonkVerifier} from "./interfaces/IHonkVerifier.sol";
import {DKIMKeyRegistry} from "./DKIMKeyRegistry.sol";

/// @title OneShotEmailGate
/// @notice The one-shot (non-persistent) on-chain path for email evidence
///         (docs/AGGREGATED_PROOFS_DESIGN.md §0.5). A user proves — in ZK, on their own device — that
///         they hold a DKIM-signed email for a specific event, and *presents* it directly to this
///         gate: verify -> DKIM key valid -> event pinned -> caller-bound -> consume a per-app
///         nullifier. Nothing is stored as a claim (no VerifiedHumansTree / RedeemIssuer / claims
///         SMT). The only on-chain trace is the spent nullifier, which is per-(app, statement,
///         context) and unlinkable across apps.
///
///         This is the deliberate opposite of the persistent path (`EmailEvidenceVerifier` ->
///         `RedeemIssuer`): use it for "let me in *now* because I attended event X", where the fact
///         needn't persist. The two interoperate — a one-shot proof and a persistent-claim proof can
///         satisfy one statement via the shared per-app nullifier.
///
/// @dev Non-transferability AND cross-app unlinkability both come from `app_id = appScope(caller,
///      statementId)` being a checked public input: the nullifier `Poseidon(secret, app_id, ctx)` is
///      thereby forced to be specific to (this caller, this statement) — a different caller yields a
///      different app_id (mismatch → revert) and a different app/statement yields an uncorrelatable
///      nullifier. Mirrors the proven `EligibilityGate` design.
contract OneShotEmailGate is Ownable {
    /// @dev BN254 scalar field modulus (the field the circuit's outputs live in).
    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev Circuit-C (one-shot) public inputs, in the order bb emits them (public params in
    ///      declaration order, then the return tuple): [app_id, context_id, keyHash0, keyHash1,
    ///      event_id, nullifier].
    uint256 internal constant N_PUB = 6;

    IHonkVerifier public immutable verifier; // one-shot Circuit-C UltraHonk verifier
    DKIMKeyRegistry public immutable dkimKeys;

    struct EmailStatement {
        bytes32 domain; // signing domain whose key must be registered (e.g. keccak("amazonses.com"))
        uint256 eventIdHash; // the event the proof must reveal ("attended event X")
        bool enabled;
    }

    mapping(bytes32 => EmailStatement) public statements;
    /// @dev Globally-unique-per-scope nullifier => consumed. The nullifier already encodes
    ///      (secret, app_id, context_id) with app_id = appScope(caller, statementId), so a flat set
    ///      is sufficient (same pattern as EligibilityGate).
    mapping(uint256 => bool) public consumedNullifier;

    event StatementRegistered(bytes32 indexed statementId, bytes32 domain, uint256 eventIdHash);
    event StatementEnabled(bytes32 indexed statementId, bool enabled);
    event Presented(
        bytes32 indexed statementId, address indexed app, uint256 indexed contextId, uint256 nullifier
    );

    error StatementNotEnabled(bytes32 statementId);
    error BadPublicInputLength(uint256 got);
    error ProofInvalid();
    error UnknownDkimKey(bytes32 domain, bytes32 keyHash0, bytes32 keyHash1);
    error WrongEvent(uint256 got, uint256 expected);
    error AppScopeMismatch(uint256 got, uint256 expected);
    error ContextMismatch(uint256 got, uint256 expected);
    error AlreadyPresented(uint256 nullifier);

    constructor(address owner_, IHonkVerifier verifier_, DKIMKeyRegistry dkimKeys_) Ownable(owner_) {
        verifier = verifier_;
        dkimKeys = dkimKeys_;
    }

    // -----------------------------------------------------------------------
    // Governance
    // -----------------------------------------------------------------------
    /// @notice Register a one-shot email statement = one (signing domain, event) pair.
    function registerStatement(bytes32 statementId, bytes32 domain, uint256 eventIdHash) external onlyOwner {
        statements[statementId] = EmailStatement({domain: domain, eventIdHash: eventIdHash, enabled: true});
        emit StatementRegistered(statementId, domain, eventIdHash);
    }

    function setStatementEnabled(bytes32 statementId, bool enabled) external onlyOwner {
        statements[statementId].enabled = enabled;
        emit StatementEnabled(statementId, enabled);
    }

    /// @notice The `app_id` a proof must carry to be presented by `caller` on `statementId`.
    ///         Binds the nullifier to (caller, statement) — non-transferable + unlinkable. Published
    ///         so clients prove with the exact value.
    function appScope(address caller, bytes32 statementId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(caller, statementId))) % P;
    }

    // -----------------------------------------------------------------------
    // Present (anyone with a valid, caller-bound one-shot proof)
    // -----------------------------------------------------------------------
    /// @param statementId which registered (domain, event) statement is being presented.
    /// @param contextId   the epoch / instance the nullifier is scoped to ("once per X").
    /// @param proof       the one-shot Circuit-C proof.
    /// @param pub         [app_id, context_id, keyHash0, keyHash1, event_id, nullifier].
    function present(bytes32 statementId, uint256 contextId, bytes calldata proof, bytes32[] calldata pub)
        external
    {
        EmailStatement memory s = statements[statementId];
        if (!s.enabled) revert StatementNotEnabled(statementId);
        if (pub.length != N_PUB) revert BadPublicInputLength(pub.length);
        if (!verifier.verify(proof, pub)) revert ProofInvalid();

        // The nullifier's scope must bind to (this caller, this statement) and this context.
        if (uint256(pub[0]) != appScope(msg.sender, statementId)) {
            revert AppScopeMismatch(uint256(pub[0]), appScope(msg.sender, statementId));
        }
        if (uint256(pub[1]) != contextId) revert ContextMismatch(uint256(pub[1]), contextId);
        // The signing key must be a registered key for the statement's domain.
        if (!dkimKeys.isValidKey(s.domain, pub[2], pub[3])) {
            revert UnknownDkimKey(s.domain, pub[2], pub[3]);
        }
        // The proof must reveal THIS statement's event ("attended event X").
        if (uint256(pub[4]) != s.eventIdHash) revert WrongEvent(uint256(pub[4]), s.eventIdHash);

        uint256 nullifier = uint256(pub[5]);
        if (consumedNullifier[nullifier]) revert AlreadyPresented(nullifier);
        consumedNullifier[nullifier] = true;

        emit Presented(statementId, msg.sender, contextId, nullifier);
    }

    /// @notice View: has this nullifier already been presented?
    function isPresented(uint256 nullifier) external view returns (bool) {
        return consumedNullifier[nullifier];
    }
}
