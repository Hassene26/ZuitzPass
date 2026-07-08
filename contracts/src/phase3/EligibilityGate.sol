// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IEligibilityVerifier} from "./interfaces/IEligibilityVerifier.sol";
import {ClaimsSMTRegistry} from "./ClaimsSMTRegistry.sol";
import {IStatementRegistry, Statement} from "../interfaces/IStatementRegistry.sol";

/// @title EligibilityGate
/// @notice Phase-3 app-facing gate (contracts/PHASE3_UNLINKABLE_DESIGN.md §3/§7). One shared
///         contract that apps call to spend a private eligibility proof: it verifies the Circuit-A
///         proof, checks the claims root is fresh, the time is sane, the proven claim types equal
///         the statement's required set, and the nullifier scope matches (app + statement + context)
///         — then consumes the nullifier once. The app learns only "eligible + this nullifier",
///         never the identity behind it.
///
/// @dev Claim types use the canonical `keccak256(name) mod p` field form (decision #1): the
///      statement stores `bytes32` keccak types; the gate reduces them mod the BN254 modulus to
///      compare against the proof's field-element `claim_types`. The prover must key its SMT leaves
///      and circuit inputs with the same reduction. Consumption is fully scoped inside the nullifier
///      (`Poseidon(secret, app_id, context_id)` with `app_id = keccak(app, statementId) mod p`), so
///      one app can never burn another's eligibility.
contract EligibilityGate is Ownable {
    /// @dev BN254 scalar field modulus (the field the circuit's `Field` type lives in).
    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    uint256 internal constant MAX_CLAIMS = 4; // must match the circuit
    uint256 internal constant N_PUB = 10; // [root,nullifier,app_id,context_id,now_ts,ct0..3,signal]

    IEligibilityVerifier public immutable verifier;
    ClaimsSMTRegistry public immutable claimsSmt;
    IStatementRegistry public immutable statements;

    /// @dev Allowed skew (seconds) between the proof's `now_ts` and `block.timestamp`.
    uint256 public timeTolerance;

    /// @dev Globally-unique-per-scope nullifier => consumed. The nullifier already encodes
    ///      (identity, app, statement, context), so a flat set is sufficient.
    mapping(uint256 => bool) public consumedNullifier;

    event Consumed(bytes32 indexed statementId, address indexed app, uint256 contextId, uint256 nullifier);
    event TimeToleranceUpdated(uint256 timeTolerance);

    error BadPublicInputLength(uint256 got);
    error ProofInvalid();
    error StaleRoot(bytes32 root);
    error TimeOutOfRange(uint256 nowTs, uint256 blockTs);
    error ContextMismatch(uint256 got, uint256 expected);
    error AppScopeMismatch(uint256 got, uint256 expected);
    error SignalMismatch(uint256 got, uint256 expected);
    error AnyOfUnsupported(); // Circuit A v1 is allOf-only
    error NotConsumable(bytes32 statementId);
    error TooManyClaims(uint256 n);
    error ClaimTypeMismatch(uint256 slot, uint256 got, uint256 expected);
    error AlreadyConsumed(uint256 nullifier);

    constructor(
        address owner_,
        IEligibilityVerifier verifier_,
        ClaimsSMTRegistry claimsSmt_,
        IStatementRegistry statements_,
        uint256 timeTolerance_
    ) Ownable(owner_) {
        verifier = verifier_;
        claimsSmt = claimsSmt_;
        statements = statements_;
        timeTolerance = timeTolerance_ == 0 ? 1 hours : timeTolerance_;
    }

    function setTimeTolerance(uint256 timeTolerance_) external onlyOwner {
        timeTolerance = timeTolerance_;
        emit TimeToleranceUpdated(timeTolerance_);
    }

    /// @notice The `app_id` a proof must carry to be spent by `app` on `statementId`.
    ///         Published so clients derive the exact value to prove with.
    function appScope(address app, bytes32 statementId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(app, statementId))) % P;
    }

    /// @notice Verify + consume a private eligibility proof. Caller (`msg.sender`) is the app.
    /// @param statementId the statement whose required claim types the proof must satisfy.
    /// @param contextId   the epoch / event instance the nullifier is scoped to.
    /// @param signal      the app-chosen binding the proof committed to (e.g. a recipient); pass 0 if unused.
    /// @param proof       the Circuit-A proof.
    /// @param pub         the circuit's public inputs (see IEligibilityVerifier).
    function consume(
        bytes32 statementId,
        uint256 contextId,
        uint256 signal,
        bytes calldata proof,
        bytes32[] calldata pub
    ) external {
        if (pub.length != N_PUB) revert BadPublicInputLength(pub.length);
        if (!verifier.verify(proof, pub)) revert ProofInvalid();

        // pub layout: [0]root [1]nullifier [2]app_id [3]context_id [4]now_ts [5..8]claim_types [9]signal
        if (!claimsSmt.isRootValid(pub[0])) revert StaleRoot(pub[0]);

        {
            uint256 nowTs = uint256(pub[4]);
            if (nowTs > block.timestamp + timeTolerance || block.timestamp > nowTs + timeTolerance) {
                revert TimeOutOfRange(nowTs, block.timestamp);
            }
        }
        if (uint256(pub[3]) != contextId) revert ContextMismatch(uint256(pub[3]), contextId);

        {
            uint256 expectedApp = appScope(msg.sender, statementId);
            if (uint256(pub[2]) != expectedApp) revert AppScopeMismatch(uint256(pub[2]), expectedApp);
        }
        {
            uint256 expectedSignal = signal % P;
            if (uint256(pub[9]) != expectedSignal) revert SignalMismatch(uint256(pub[9]), expectedSignal);
        }

        _assertClaimTypesMatch(statementId, pub);

        uint256 nullifier = uint256(pub[1]);
        if (consumedNullifier[nullifier]) revert AlreadyConsumed(nullifier);
        consumedNullifier[nullifier] = true;

        emit Consumed(statementId, msg.sender, contextId, nullifier);
    }

    /// @dev The proof's `claim_types` slots must equal the statement's `allOf` reduced mod p, in
    ///      order, with unused slots == 0. anyOf is not supported by Circuit A v1.
    function _assertClaimTypesMatch(bytes32 statementId, bytes32[] calldata pub) internal view {
        Statement memory s = statements.getStatement(statementId);
        if (s.anyOf.length != 0) revert AnyOfUnsupported();
        if (!s.consumable) revert NotConsumable(statementId);
        if (s.allOf.length > MAX_CLAIMS) revert TooManyClaims(s.allOf.length);

        for (uint256 i = 0; i < MAX_CLAIMS; i++) {
            uint256 expected = i < s.allOf.length ? uint256(s.allOf[i]) % P : 0;
            uint256 got = uint256(pub[5 + i]);
            if (got != expected) revert ClaimTypeMismatch(i, got, expected);
        }
    }
}
