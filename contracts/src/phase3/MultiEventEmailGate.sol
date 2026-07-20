// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHonkVerifier} from "./interfaces/IHonkVerifier.sol";
import {DKIMKeyRegistry} from "./DKIMKeyRegistry.sol";

/// @title MultiEventEmailGate
/// @notice One-shot COMPOSITION (docs/AGGREGATED_PROOFS_DESIGN.md §0.5 "the unifying trick"): a
///         statement requires a *set* of events, and the user presents one Circuit-C(one-shot) proof
///         per event in a single call. The gate accepts iff:
///           - every proof verifies and its DKIM key is registered for the statement's domain;
///           - the multiset of revealed `event_id`s exactly covers the required set (conjunction);
///           - all proofs carry the SAME nullifier `Poseidon(secret, app_id, ctx)` -> same person
///             (only the secret-holder can produce a matching one, so facts can't be pooled across
///             people), and the SAME caller-bound `app_id` (non-transferable) and context;
///         then it consumes the one shared nullifier. Nothing is stored beyond the burned nullifier.
///
///         The single-event `OneShotEmailGate` is the N=1 special case; this generalizes it to
///         "attended X AND Y AND ...". Each proof is the SAME unchanged one-shot circuit — the
///         prover just runs it once per email with the same secret/app_id/context, yielding an
///         identical nullifier across proofs.
///
/// @dev A future cross-type composition (email event AND World-ID personhood) is the same shape: any
///      proof system emitting `Poseidon(secret, app_id, ctx)` shares the nullifier; only its verifier
///      + fact-check differ. This contract covers the same-circuit (email) case.
contract MultiEventEmailGate is Ownable {
    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev one-shot Circuit-C pub layout: [app_id, context_id, keyHash0, keyHash1, event_id, nullifier].
    uint256 internal constant N_PUB = 6;
    uint256 internal constant MAX_EVENTS = 8; // cap on a statement's required set

    IHonkVerifier public immutable verifier;
    DKIMKeyRegistry public immutable dkimKeys;

    struct Statement {
        bytes32 domain; // signing domain whose key must be registered (e.g. keccak("amazonses.com"))
        uint256[] requiredEventIds; // the set of events that must ALL be presented
        bool enabled;
    }

    mapping(bytes32 => Statement) internal _statements;
    mapping(uint256 => bool) public consumedNullifier;

    event StatementRegistered(bytes32 indexed statementId, bytes32 domain, uint256 nEvents);
    event StatementEnabled(bytes32 indexed statementId, bool enabled);
    event Presented(bytes32 indexed statementId, address indexed app, uint256 indexed contextId, uint256 nullifier);

    error StatementNotEnabled(bytes32 statementId);
    error WrongProofCount(uint256 got, uint256 expected);
    error BadPublicInputLength(uint256 index, uint256 got);
    error ProofInvalid(uint256 index);
    error UnknownDkimKey(uint256 index, bytes32 domain, bytes32 keyHash0, bytes32 keyHash1);
    error AppScopeMismatch(uint256 index, uint256 got, uint256 expected);
    error ContextMismatch(uint256 index, uint256 got, uint256 expected);
    error NullifierMismatch(uint256 index); // a proof from a different person (different nullifier)
    error EventNotCovered(uint256 index, uint256 eventId); // proof's event isn't a fresh required one
    error TooManyEvents(uint256 n);
    error AlreadyPresented(uint256 nullifier);

    constructor(address owner_, IHonkVerifier verifier_, DKIMKeyRegistry dkimKeys_) Ownable(owner_) {
        verifier = verifier_;
        dkimKeys = dkimKeys_;
    }

    // -----------------------------------------------------------------------
    // Governance
    // -----------------------------------------------------------------------
    function registerStatement(bytes32 statementId, bytes32 domain, uint256[] calldata requiredEventIds)
        external
        onlyOwner
    {
        if (requiredEventIds.length == 0 || requiredEventIds.length > MAX_EVENTS) {
            revert TooManyEvents(requiredEventIds.length);
        }
        _statements[statementId] =
            Statement({domain: domain, requiredEventIds: requiredEventIds, enabled: true});
        emit StatementRegistered(statementId, domain, requiredEventIds.length);
    }

    function setStatementEnabled(bytes32 statementId, bool enabled) external onlyOwner {
        _statements[statementId].enabled = enabled;
        emit StatementEnabled(statementId, enabled);
    }

    function getStatement(bytes32 statementId) external view returns (Statement memory) {
        return _statements[statementId];
    }

    function appScope(address caller, bytes32 statementId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(caller, statementId))) % P;
    }

    // -----------------------------------------------------------------------
    // Present the whole conjunction (one proof per required event)
    // -----------------------------------------------------------------------
    /// @param statementId the statement whose required event set must be covered.
    /// @param contextId    the epoch / instance the (shared) nullifier is scoped to.
    /// @param proofs       one one-shot proof per required event, in any order.
    /// @param pubs         the matching public inputs; pubs[i] = [app_id, ctx, kh0, kh1, event_id, nullifier].
    function present(bytes32 statementId, uint256 contextId, bytes[] calldata proofs, bytes32[][] calldata pubs)
        external
    {
        Statement storage s = _statements[statementId];
        if (!s.enabled) revert StatementNotEnabled(statementId);

        uint256 n = s.requiredEventIds.length;
        if (proofs.length != n || pubs.length != n) revert WrongProofCount(proofs.length, n);

        uint256 expectedApp = appScope(msg.sender, statementId);
        uint256 nullifier = uint256(pubs[0][5]);

        bool[MAX_EVENTS] memory covered; // which required events have been matched (unique)

        for (uint256 i = 0; i < n; i++) {
            bytes32[] calldata pi = pubs[i];
            if (pi.length != N_PUB) revert BadPublicInputLength(i, pi.length);
            if (!verifier.verify(proofs[i], pi)) revert ProofInvalid(i);

            if (uint256(pi[0]) != expectedApp) revert AppScopeMismatch(i, uint256(pi[0]), expectedApp);
            if (uint256(pi[1]) != contextId) revert ContextMismatch(i, uint256(pi[1]), contextId);
            if (uint256(pi[5]) != nullifier) revert NullifierMismatch(i); // same person across all proofs
            if (!dkimKeys.isValidKey(s.domain, pi[2], pi[3])) {
                revert UnknownDkimKey(i, s.domain, pi[2], pi[3]);
            }

            // Cover a still-unmatched required event with this proof's event_id.
            uint256 eventId = uint256(pi[4]);
            bool matched = false;
            for (uint256 j = 0; j < n; j++) {
                if (!covered[j] && s.requiredEventIds[j] == eventId) {
                    covered[j] = true;
                    matched = true;
                    break;
                }
            }
            if (!matched) revert EventNotCovered(i, eventId);
        }
        // n proofs each covered a distinct required event, and there are n required events -> full set.

        if (consumedNullifier[nullifier]) revert AlreadyPresented(nullifier);
        consumedNullifier[nullifier] = true;

        emit Presented(statementId, msg.sender, contextId, nullifier);
    }

    function isPresented(uint256 nullifier) external view returns (bool) {
        return consumedNullifier[nullifier];
    }
}
