// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {AQueryProofExecutor} from "./rarimo/sdk/AQueryProofExecutor.sol";
import {PublicSignalsBuilder} from "./rarimo/sdk/lib/PublicSignalsBuilder.sol";
import {INullifierBanControl} from "./interfaces/INullifierBanControl.sol";
import {IClaimsRegistry} from "./interfaces/IClaimsRegistry.sol";

/// @title ZuitzPassExecutor
/// @notice The Rarimo-path gate for the Zuitzerland gated anonymous forum (E2E flow Phase 4).
///         Inherits Rarimo's `AQueryProofExecutor`: the user submits a Query proof about a
///         passport registered in Rarimo's `RegistrationSMT`, and this contract:
///           - `_beforeVerify`   — rejects banned / already-used nullifiers
///           - `_buildPublicSignals` — pins the ZuitzPass query: scope (`eventId`),
///                                 uniqueness, optional age / not-expired criteria
///           - (base) verifies the Groth16 proof via `TD3QueryProofVerifier`, and validates
///                                 the registration root freshness via `IPoseidonSMT.isRootValid`
///           - `_afterVerify`    — consumes the nullifier and grants access
///
/// @dev Upgradeable-style (the base is `Initializable`); deploy behind a proxy or use directly
///      after `initialize`. Criteria beyond "unique registered human" are owner-configurable
///      policy — this is the `IIdentityAdapter` idea from ARCHITECTURE.md §9, concrete for Rarimo.
contract ZuitzPassExecutor is AQueryProofExecutor, OwnableUpgradeable, INullifierBanControl {
    // -----------------------------------------------------------------------
    // Query-circuit selector bits (0-indexed).
    // Sources: rarimo/passport-zk-circuits README "selector" + verificator-svc query-proof
    // parameter table (uniqueness = 2560 = bits 9+11). Final confirmation = real-proof replay.
    // -----------------------------------------------------------------------
    uint256 internal constant SEL_NULLIFIER = 1 << 0;
    uint256 internal constant SEL_TIMESTAMP_UPPER = 1 << 9;
    uint256 internal constant SEL_ID_COUNTER_UPPER = 1 << 11;
    uint256 internal constant SEL_EXPIRATION_LOWER = 1 << 12;
    uint256 internal constant SEL_BIRTHDATE_LOWER = 1 << 14;
    uint256 internal constant SEL_BIRTHDATE_UPPER = 1 << 15;

    // -----------------------------------------------------------------------
    // Statements-layer issuance (ARCHITECTURE_UPDATED.md §2.3) — additive, opt-in.
    // On a successful verify this gate becomes an *issuer* of these claim types.
    // -----------------------------------------------------------------------
    /// @dev Provider namespace for the layer subject `keccak256(PROVIDER_ID, nullifier)`.
    string internal constant PROVIDER_ID = "rarimo";
    bytes32 public constant UNIQUE_HUMAN_RARIMO = keccak256("UNIQUE_HUMAN_RARIMO");
    bytes32 public constant OVER_18 = keccak256("OVER_18");

    // -----------------------------------------------------------------------
    // Policy (owner-configurable gate criteria)
    // -----------------------------------------------------------------------
    /// @dev Fixed ZuitzPass scope. Makes nullifiers untraceable across apps AND stable per
    ///      (person, ZuitzPass) → one human, one account.
    uint256 public eventId;
    /// @dev Uniqueness upper bound on the passport's identity counter (e.g. 1 = one identity).
    uint256 public identityCounterUpperbound;
    /// @dev Uniqueness registration cutoff (unix ts). Rarimo's uniqueness is the OR:
    ///      identity registered before this timestamp, OR identity counter ≤ bound. Matches
    ///      verificator-svc's `uniqueness` (selector bits 9+11) so SDK proofs verify.
    uint256 public timestampUpperbound;
    /// @dev Age gate: prove birth date is on/before this `yyMMdd` (ASCII) value. 0 = disabled.
    uint256 public birthDateUpperbound;
    /// @dev If true, prove the passport's expiration date is after `currentDate` (not expired).
    bool public requireNotExpired;
    /// @dev If true, enforce the identity-counter uniqueness bound above.
    bool public requireUniqueness;
    /// @dev Tolerance (seconds) for how far `currentDate` may sit from `block.timestamp`.
    uint256 public currentDateTimeBound;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------
    mapping(bytes32 => bool) public usedNullifiers;
    mapping(bytes32 => bool) public bannedNullifiers;
    address public governance;

    /// @dev Optional statements-layer sink. Zero = issuance off (behavior unchanged from Phase 0).
    IClaimsRegistry public claimsRegistry;
    /// @dev Expiry applied to issued claims (owner-set; 180 days at initialize).
    uint64 public claimValidity;

    /// @notice Application data the caller encodes into `userPayload_` for `execute(...)`.
    /// @param nullifier The proof's nullifier (public signal #0), scoped to `eventId`.
    /// @param eventData Arbitrary data bound into the proof (e.g. the forum session / wallet).
    struct QueryPayload {
        uint256 nullifier;
        uint256 eventData;
    }

    struct InitParams {
        address registrationSMT; // RegistrationSMTReplicator (or the SMT) on THIS chain
        address verifier; // TD3QueryProofVerifier (Groth16)
        address owner;
        uint256 eventId;
        uint256 identityCounterUpperbound;
        uint256 timestampUpperbound; // 0 = block.timestamp at initialize
        bool requireUniqueness;
        bool requireNotExpired;
        uint256 birthDateUpperbound;
        uint256 currentDateTimeBound;
    }

    event AccessGranted(address indexed caller, bytes32 indexed nullifier, uint256 eventData);
    event GovernanceUpdated(address governance);
    event PolicyUpdated();
    event ClaimsRegistryUpdated(address claimsRegistry);
    event ClaimValidityUpdated(uint64 claimValidity);

    error NullifierBanned();
    error NullifierAlreadyUsed();
    error NotGovernance();

    /// @dev Deployed directly and `initialize`d (PoC). For a proxy deployment, add a
    ///      `constructor() { _disableInitializers(); }` to the implementation.
    function initialize(InitParams calldata p) external initializer {
        __AQueryProofExecutor_init(p.registrationSMT, p.verifier);
        __Ownable_init(p.owner);

        eventId = p.eventId;
        identityCounterUpperbound = p.identityCounterUpperbound;
        timestampUpperbound = p.timestampUpperbound == 0 ? block.timestamp : p.timestampUpperbound;
        requireUniqueness = p.requireUniqueness;
        requireNotExpired = p.requireNotExpired;
        birthDateUpperbound = p.birthDateUpperbound;
        currentDateTimeBound = p.currentDateTimeBound == 0 ? 1 days : p.currentDateTimeBound;
        claimValidity = 180 days;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------
    function setGovernance(address governance_) external onlyOwner {
        governance = governance_;
        emit GovernanceUpdated(governance_);
    }

    /// @notice Wire (or unset) the statements-layer `ClaimsRegistry`. Zero disables issuance —
    ///         the gate then behaves exactly as in Phase 0. The registry must also permission
    ///         this contract as an issuer of `UNIQUE_HUMAN_RARIMO` / `OVER_18`.
    function setClaimsRegistry(address claimsRegistry_) external onlyOwner {
        claimsRegistry = IClaimsRegistry(claimsRegistry_);
        emit ClaimsRegistryUpdated(claimsRegistry_);
    }

    /// @notice Set the expiry applied to issued claims (0 = never expire).
    function setClaimValidity(uint64 claimValidity_) external onlyOwner {
        claimValidity = claimValidity_;
        emit ClaimValidityUpdated(claimValidity_);
    }

    /// @inheritdoc INullifierBanControl
    function setNullifierBanned(bytes32 nullifier, bool banned) external override onlyGovernance {
        bannedNullifiers[nullifier] = banned;
    }

    function setPolicy(
        uint256 identityCounterUpperbound_,
        uint256 timestampUpperbound_,
        bool requireUniqueness_,
        bool requireNotExpired_,
        uint256 birthDateUpperbound_,
        uint256 currentDateTimeBound_
    ) external onlyOwner {
        identityCounterUpperbound = identityCounterUpperbound_;
        timestampUpperbound = timestampUpperbound_ == 0 ? block.timestamp : timestampUpperbound_;
        requireUniqueness = requireUniqueness_;
        requireNotExpired = requireNotExpired_;
        birthDateUpperbound = birthDateUpperbound_;
        currentDateTimeBound = currentDateTimeBound_ == 0 ? 1 days : currentDateTimeBound_;
        emit PolicyUpdated();
    }

    /// @notice The selector bitmask enforced by the current policy (exposed for clients/tests).
    function selector() public view returns (uint256 sel_) {
        sel_ = SEL_NULLIFIER;
        // Rarimo "uniqueness" (verificator-svc selector 2560): registered before the
        // timestamp cutoff OR identity counter within bound.
        if (requireUniqueness) sel_ |= SEL_TIMESTAMP_UPPER | SEL_ID_COUNTER_UPPER;
        if (requireNotExpired) sel_ |= SEL_EXPIRATION_LOWER;
        if (birthDateUpperbound != 0) sel_ |= SEL_BIRTHDATE_LOWER | SEL_BIRTHDATE_UPPER;
    }

    // -----------------------------------------------------------------------
    // AQueryProofExecutor hooks
    // -----------------------------------------------------------------------
    function _beforeVerify(
        bytes32,
        uint256,
        bytes memory userPayload_
    ) internal view override {
        bytes32 n = bytes32(_decode(userPayload_).nullifier);
        if (bannedNullifiers[n]) revert NullifierBanned();
        if (usedNullifiers[n]) revert NullifierAlreadyUsed();
    }

    function _buildPublicSignals(
        bytes32,
        uint256 currentDate_,
        bytes memory userPayload_
    ) internal view override returns (uint256 builder_) {
        QueryPayload memory p = _decode(userPayload_);

        builder_ = PublicSignalsBuilder.newPublicSignalsBuilder(selector(), p.nullifier);
        PublicSignalsBuilder.withEventIdAndData(builder_, eventId, p.eventData);
        PublicSignalsBuilder.withCurrentDate(builder_, currentDate_, currentDateTimeBound);

        if (requireUniqueness) {
            PublicSignalsBuilder.withTimestampLowerboundAndUpperbound(builder_, 0, timestampUpperbound);
            PublicSignalsBuilder.withIdentityCounterLowerbound(builder_, 0, identityCounterUpperbound);
        }
        if (requireNotExpired) {
            // Prove passport expiration > currentDate (lower bound is the meaningful side).
            PublicSignalsBuilder.withExpirationDateLowerboundAndUpperbound(
                builder_,
                currentDate_,
                PublicSignalsBuilder.ZERO_DATE
            );
        }
        if (birthDateUpperbound != 0) {
            // Prove birth date <= birthDateUpperbound (e.g. born on/before "today − 18y").
            PublicSignalsBuilder.withBirthDateLowerboundAndUpperbound(
                builder_,
                PublicSignalsBuilder.ZERO_DATE,
                birthDateUpperbound
            );
        }
        // NOTE: the base `execute()` appends `withIdStateRoot(root)` after this returns,
        // which validates registration-root freshness via IPoseidonSMT.isRootValid.
    }

    /// @dev ZuitzPass gates on TD3 passports; TD1 is unsupported.
    function _buildPublicSignalsTD1(
        bytes32,
        uint256,
        bytes memory
    ) internal view override returns (uint256) {
        revert("ZuitzPass: TD1 unsupported");
    }

    function _afterVerify(
        bytes32,
        uint256,
        bytes memory userPayload_
    ) internal override {
        QueryPayload memory p = _decode(userPayload_);
        bytes32 n = bytes32(p.nullifier);
        usedNullifiers[n] = true;
        emit AccessGranted(msg.sender, n, p.eventData);

        // §2.3 issuance hook (additive, opt-in). `usedNullifiers` above stays the proof-replay
        // guard; the registry handles eligibility. Same passport Query proof yields personhood
        // and — when the age gate is on — the OVER_18 claim (age is a selector bit already set).
        IClaimsRegistry registry = claimsRegistry;
        if (address(registry) != address(0)) {
            bytes32 subject = keccak256(abi.encode(PROVIDER_ID, p.nullifier));
            uint64 expiry = claimValidity == 0 ? 0 : uint64(block.timestamp) + claimValidity;
            registry.issue(subject, UNIQUE_HUMAN_RARIMO, expiry);
            if (birthDateUpperbound != 0) {
                registry.issue(subject, OVER_18, expiry);
            }
        }
    }

    function _decode(bytes memory userPayload_) private pure returns (QueryPayload memory) {
        return abi.decode(userPayload_, (QueryPayload));
    }
}
