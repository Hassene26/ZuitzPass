// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IClaimsRegistry, Claim} from "./interfaces/IClaimsRegistry.sol";
import {INullifierBanControl} from "./interfaces/INullifierBanControl.sol";

/// @title ClaimsRegistry
/// @notice Layer-1 output of the zk statements layer (ARCHITECTURE_UPDATED.md §2.1): the spine
///         that permissioned issuers write typed claims into and apps read from. A "claim" is a
///         typed fact — `UNIQUE_HUMAN_RARIMO`, `OVER_18`, `ZUITZ_MAY25_ATTENDEE` — bound to a
///         `subject` (a provider-namespaced nullifier, `keccak256(providerId, nullifier)`).
///
///         Roles:
///           - `owner`      (governance multisig): registers claim types, permissions issuers.
///           - issuers      (the gates / attestors): call `issue` / `revoke` for allowed types.
///           - `governance` (the `ZuitzerlandGovernance` wrapper): layer-wide subject bans via
///                          `INullifierBanControl` — banning a subject invalidates ALL of its
///                          claims at once (strictly stronger than the old per-gate ban).
///
/// @dev Mirrors the two-key split of the existing gates: `owner` administers config, a separate
///      `governance` pointer holds the ban key so `ZuitzerlandGovernance` drives it unchanged.
contract ClaimsRegistry is IClaimsRegistry, Ownable {
    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------
    /// @dev Registered claim types (only registered types can be issued).
    mapping(bytes32 => bool) public claimTypeRegistered;
    /// @dev Off-chain descriptor per claim type (display name, evidence mechanism docs).
    mapping(bytes32 => string) public claimTypeURI;
    /// @dev allowedIssuer[claimType][issuer] — who may write a given claim type.
    mapping(bytes32 => mapping(address => bool)) public allowedIssuer;
    /// @dev claims[subject][claimType].
    mapping(bytes32 => mapping(bytes32 => Claim)) internal _claims;
    /// @dev Layer-wide subject bans (kills every claim the subject holds).
    mapping(bytes32 => bool) public bannedSubjects;

    /// @dev The `ZuitzerlandGovernance` wrapper permitted to (un)ban subjects.
    address public governance;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event ClaimTypeRegistered(bytes32 indexed claimType, string metadataURI);
    event IssuerSet(bytes32 indexed claimType, address indexed issuer, bool allowed);
    event ClaimIssued(bytes32 indexed subject, bytes32 indexed claimType, address indexed issuer, uint64 expiresAt);
    event ClaimRevoked(bytes32 indexed subject, bytes32 indexed claimType, address indexed by);
    event SubjectBanUpdated(bytes32 indexed subject, bool banned);
    event GovernanceUpdated(address governance);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error ClaimTypeAlreadyRegistered(bytes32 claimType);
    error ClaimTypeNotRegistered(bytes32 claimType);
    error NotAuthorizedIssuer(bytes32 claimType, address caller);
    error ClaimNotFound(bytes32 subject, bytes32 claimType);
    error NotGovernance();

    constructor(address owner_) Ownable(owner_) {}

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    // -----------------------------------------------------------------------
    // Governance (owner = multisig)
    // -----------------------------------------------------------------------
    /// @notice Point the ban key at the `ZuitzerlandGovernance` wrapper.
    function setGovernance(address governance_) external onlyOwner {
        governance = governance_;
        emit GovernanceUpdated(governance_);
    }

    /// @inheritdoc IClaimsRegistry
    function registerClaimType(bytes32 claimType, string calldata metadataURI) external override onlyOwner {
        if (claimTypeRegistered[claimType]) revert ClaimTypeAlreadyRegistered(claimType);
        claimTypeRegistered[claimType] = true;
        claimTypeURI[claimType] = metadataURI;
        emit ClaimTypeRegistered(claimType, metadataURI);
    }

    /// @inheritdoc IClaimsRegistry
    function setIssuer(bytes32 claimType, address issuer, bool allowed) external override onlyOwner {
        if (!claimTypeRegistered[claimType]) revert ClaimTypeNotRegistered(claimType);
        allowedIssuer[claimType][issuer] = allowed;
        emit IssuerSet(claimType, issuer, allowed);
    }

    // -----------------------------------------------------------------------
    // Issuers
    // -----------------------------------------------------------------------
    /// @inheritdoc IClaimsRegistry
    /// @dev Idempotent per (subject, claimType): re-issuing overwrites (e.g. refreshes expiry).
    function issue(bytes32 subject, bytes32 claimType, uint64 expiresAt) external override {
        if (!allowedIssuer[claimType][msg.sender]) revert NotAuthorizedIssuer(claimType, msg.sender);
        _claims[subject][claimType] =
            Claim({issuer: msg.sender, issuedAt: uint64(block.timestamp), expiresAt: expiresAt});
        emit ClaimIssued(subject, claimType, msg.sender, expiresAt);
    }

    /// @inheritdoc IClaimsRegistry
    /// @dev Callable by governance (owner) or any currently-allowed issuer of the claim type.
    function revoke(bytes32 subject, bytes32 claimType) external override {
        if (msg.sender != owner() && !allowedIssuer[claimType][msg.sender]) {
            revert NotAuthorizedIssuer(claimType, msg.sender);
        }
        if (_claims[subject][claimType].issuer == address(0)) revert ClaimNotFound(subject, claimType);
        delete _claims[subject][claimType];
        emit ClaimRevoked(subject, claimType, msg.sender);
    }

    // -----------------------------------------------------------------------
    // Ban integration (INullifierBanControl, driven by ZuitzerlandGovernance)
    // -----------------------------------------------------------------------
    /// @inheritdoc INullifierBanControl
    /// @dev `nullifier` is the layer subject `keccak256(providerId, providerNullifier)`.
    function setNullifierBanned(bytes32 nullifier, bool banned) external override onlyGovernance {
        bannedSubjects[nullifier] = banned;
        emit SubjectBanUpdated(nullifier, banned);
    }

    // -----------------------------------------------------------------------
    // Reads (anyone)
    // -----------------------------------------------------------------------
    /// @inheritdoc IClaimsRegistry
    function hasValidClaim(bytes32 subject, bytes32 claimType) public view override returns (bool) {
        if (bannedSubjects[subject]) return false;
        Claim storage c = _claims[subject][claimType];
        if (c.issuer == address(0)) return false; // no claim
        if (c.expiresAt != 0 && c.expiresAt <= block.timestamp) return false; // expired
        return true;
    }

    /// @inheritdoc IClaimsRegistry
    function getClaim(bytes32 subject, bytes32 claimType) external view override returns (Claim memory) {
        return _claims[subject][claimType];
    }
}
