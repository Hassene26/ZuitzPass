// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IWorldID} from "../interfaces/IWorldID.sol";
import {ByteHasher} from "../lib/ByteHasher.sol";
import {IHonkVerifier} from "./interfaces/IHonkVerifier.sol";
import {DKIMKeyRegistry} from "./DKIMKeyRegistry.sol";

/// @title HumanEventGate
/// @notice CROSS-TYPE one-shot composition (docs/AGGREGATED_PROOFS_DESIGN.md §0.5): a statement of
///         the form "a UNIQUE HUMAN who attended events X..Z", satisfied in ONE call by a World ID
///         personhood proof PLUS one Circuit-C(one-shot) email proof per required event. Nothing is
///         stored beyond the spent nullifiers.
///
///         Unlike same-circuit composition (`MultiEventEmailGate`), the two fact TYPES come from
///         different proof systems (World ID = Semaphore/Groth16 via the Router; email = UltraHonk),
///         so they can't share one nullifier. The binding is instead the CALLER: the World ID proof
///         is generated with `signal = msg.sender`, and the email proofs carry
///         `app_id = appScope(msg.sender, statementId)`. So "the same wallet is a verified human AND
///         presented these attendances" — non-transferable, and the World ID nullifier gives
///         one-human-per-(statement,context) sybil resistance.
///
/// @dev This is the generalization pattern: any additional proof system composes by binding to the
///      caller (or, when it knows the master secret, by the shared per-app nullifier).
contract HumanEventGate is Ownable {
    using ByteHasher for bytes;

    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev one-shot Circuit-C email pub layout: [app_id, context_id, keyHash0, keyHash1, event_id, nullifier].
    uint256 internal constant N_PUB = 6;
    uint256 internal constant MAX_EVENTS = 8;

    // World ID
    IWorldID internal immutable worldId;
    uint256 internal immutable groupId = 1; // Orb
    uint256 public immutable externalNullifier; // hashToField(hashToField(appId), action)

    // Email
    IHonkVerifier public immutable emailVerifier;
    DKIMKeyRegistry public immutable dkimKeys;

    struct Statement {
        bytes32 domain; // signing domain whose key must be registered (e.g. keccak("amazonses.com"))
        uint256[] requiredEventIds; // events that must ALL be attended
        bool enabled;
    }

    mapping(bytes32 => Statement) internal _statements;
    /// @dev World ID nullifier consumed per (statement, context) -> one human per context.
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => bool))) public consumedHuman;
    /// @dev email per-app nullifier consumed (flat; already encodes app+context).
    mapping(uint256 => bool) public consumedEmailNullifier;

    event StatementRegistered(bytes32 indexed statementId, bytes32 domain, uint256 nEvents);
    event StatementEnabled(bytes32 indexed statementId, bool enabled);
    event Presented(
        bytes32 indexed statementId, address indexed caller, uint256 indexed contextId, uint256 humanNullifier
    );

    error StatementNotEnabled(bytes32 statementId);
    error WrongProofCount(uint256 got, uint256 expected);
    error BadPublicInputLength(uint256 index, uint256 got);
    error EmailProofInvalid(uint256 index);
    error UnknownDkimKey(uint256 index, bytes32 domain, bytes32 keyHash0, bytes32 keyHash1);
    error AppScopeMismatch(uint256 index, uint256 got, uint256 expected);
    error ContextMismatch(uint256 index, uint256 got, uint256 expected);
    error EventNotCovered(uint256 index, uint256 eventId);
    error TooManyEvents(uint256 n);
    error HumanAlreadyUsed(uint256 humanNullifier); // one human per (statement, context)
    error EmailAlreadyPresented(uint256 nullifier);

    constructor(
        address owner_,
        IWorldID worldId_,
        string memory appId_,
        string memory action_,
        IHonkVerifier emailVerifier_,
        DKIMKeyRegistry dkimKeys_
    ) Ownable(owner_) {
        worldId = worldId_;
        externalNullifier = abi.encodePacked(abi.encodePacked(appId_).hashToField(), action_).hashToField();
        emailVerifier = emailVerifier_;
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
        _statements[statementId] = Statement({domain: domain, requiredEventIds: requiredEventIds, enabled: true});
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
    // Present: World ID personhood + the email event set, all bound to the caller
    // -----------------------------------------------------------------------
    struct WorldIDProof {
        uint256 root;
        uint256 nullifierHash;
        uint256[8] proof;
    }

    /// @param statementId   the "human AND attended {events}" statement.
    /// @param contextId     epoch / instance (scopes the email nullifiers + the human nullifier).
    /// @param wid           the World ID proof (generated with signal = msg.sender).
    /// @param emailProofs   one one-shot email proof per required event.
    /// @param emailPubs     matching public inputs; each = [app_id, ctx, kh0, kh1, event_id, nullifier].
    function present(
        bytes32 statementId,
        uint256 contextId,
        WorldIDProof calldata wid,
        bytes[] calldata emailProofs,
        bytes32[][] calldata emailPubs
    ) external {
        Statement storage s = _statements[statementId];
        if (!s.enabled) revert StatementNotEnabled(statementId);

        uint256 n = s.requiredEventIds.length;
        if (emailProofs.length != n || emailPubs.length != n) revert WrongProofCount(emailProofs.length, n);

        // 1) Personhood: a unique human, bound to THIS caller (signal), fresh per (statement, context).
        if (consumedHuman[statementId][contextId][wid.nullifierHash]) revert HumanAlreadyUsed(wid.nullifierHash);
        worldId.verifyProof(
            wid.root,
            groupId,
            abi.encodePacked(msg.sender).hashToField(), // signal = caller
            wid.nullifierHash,
            externalNullifier,
            wid.proof
        );
        consumedHuman[statementId][contextId][wid.nullifierHash] = true;

        // 2) Attendance: cover every required event with a caller-bound email proof.
        uint256 expectedApp = appScope(msg.sender, statementId);
        bool[MAX_EVENTS] memory covered;

        for (uint256 i = 0; i < n; i++) {
            bytes32[] calldata pi = emailPubs[i];
            if (pi.length != N_PUB) revert BadPublicInputLength(i, pi.length);
            if (!emailVerifier.verify(emailProofs[i], pi)) revert EmailProofInvalid(i);

            if (uint256(pi[0]) != expectedApp) revert AppScopeMismatch(i, uint256(pi[0]), expectedApp);
            if (uint256(pi[1]) != contextId) revert ContextMismatch(i, uint256(pi[1]), contextId);
            if (!dkimKeys.isValidKey(s.domain, pi[2], pi[3])) revert UnknownDkimKey(i, s.domain, pi[2], pi[3]);

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

            uint256 nul = uint256(pi[5]);
            if (consumedEmailNullifier[nul]) revert EmailAlreadyPresented(nul);
            consumedEmailNullifier[nul] = true;
        }

        emit Presented(statementId, msg.sender, contextId, wid.nullifierHash);
    }
}
