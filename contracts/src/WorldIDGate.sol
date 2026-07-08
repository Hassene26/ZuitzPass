// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IWorldID} from "./interfaces/IWorldID.sol";
import {INullifierBanControl} from "./interfaces/INullifierBanControl.sol";
import {IClaimsRegistry} from "./interfaces/IClaimsRegistry.sol";
import {ByteHasher} from "./lib/ByteHasher.sol";

/// @title WorldIDGate
/// @notice ZuitzPass gate backed by **World ID** proof-of-personhood (an alternative to the
///         Rarimo path — same gate shape, different provider, per ARCHITECTURE.md §9).
///         A user proves they're a unique human for a fixed `(appId, action)` scope; the gate:
///           - rejects banned / already-used nullifiers
///           - calls the World ID Router's `verifyProof` (reverts on a bad proof)
///           - consumes the nullifier and grants access
///
/// @dev No passport/biometric is needed to TEST this: World ID's simulator
///      (simulator.worldcoin.org, staging) issues valid proofs. Reuses `ZuitzerlandGovernance`
///      via `INullifierBanControl`.
contract WorldIDGate is Ownable, INullifierBanControl {
    using ByteHasher for bytes;

    /// @dev The World ID Router (verifies proofs against the on-chain identity tree).
    IWorldID internal immutable worldId;
    /// @dev Orb credential group.
    uint256 internal immutable groupId = 1;
    /// @dev `hashToField(hashToField(appId), action)` — the fixed ZuitzPass scope; makes the
    ///      nullifier stable per (person, ZuitzPass action) → one human, one account.
    uint256 internal immutable externalNullifier;

    /// @dev Provider namespace for the layer subject `keccak256(PROVIDER_ID, nullifierHash)`.
    string internal constant PROVIDER_ID = "worldid";
    bytes32 public constant UNIQUE_HUMAN_WORLDID = keccak256("UNIQUE_HUMAN_WORLDID");

    mapping(uint256 => bool) public usedNullifiers;
    mapping(uint256 => bool) public bannedNullifiers;
    address public governance;

    /// @dev Optional statements-layer sink. Zero = issuance off (behavior unchanged from Phase 0).
    IClaimsRegistry public claimsRegistry;
    /// @dev Expiry applied to issued claims (owner-set; 180 days by default). 0 = never expire.
    uint64 public claimValidity = 180 days;

    event AccessGranted(address indexed caller, uint256 nullifierHash, address signal);
    event GovernanceUpdated(address governance);
    event ClaimsRegistryUpdated(address claimsRegistry);
    event ClaimValidityUpdated(uint64 claimValidity);

    error DuplicateNullifier(uint256 nullifierHash);
    error NullifierBanned();
    error NotGovernance();

    /// @param _worldId The World ID Router address for the target chain.
    /// @param _appId The World ID app id (e.g. "app_staging_...").
    /// @param _action The action string (the ZuitzPass scope, e.g. "zuitzpass-access").
    constructor(IWorldID _worldId, string memory _appId, string memory _action) Ownable(msg.sender) {
        worldId = _worldId;
        externalNullifier = abi.encodePacked(abi.encodePacked(_appId).hashToField(), _action).hashToField();
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    /// @notice Verify a World ID proof and grant access.
    /// @param signal Arbitrary data bound into the proof (e.g. the user's wallet). Must match
    ///        the signal the proof was generated for.
    /// @param root The World ID Merkle root the proof was generated against.
    /// @param nullifierHash The proof's nullifier (per app+action uniqueness).
    /// @param proof The 8-element proof from IDKit / the simulator.
    function verify(
        address signal,
        uint256 root,
        uint256 nullifierHash,
        uint256[8] calldata proof
    ) external {
        if (bannedNullifiers[nullifierHash]) revert NullifierBanned();
        if (usedNullifiers[nullifierHash]) revert DuplicateNullifier(nullifierHash);

        // Reverts if the proof is invalid.
        worldId.verifyProof(
            root,
            groupId,
            abi.encodePacked(signal).hashToField(),
            nullifierHash,
            externalNullifier,
            proof
        );

        usedNullifiers[nullifierHash] = true;
        emit AccessGranted(msg.sender, nullifierHash, signal);

        // §2.3 issuance hook (additive, opt-in). `usedNullifiers` above stays the proof-replay
        // guard; the registry handles eligibility.
        IClaimsRegistry registry = claimsRegistry;
        if (address(registry) != address(0)) {
            bytes32 subject = keccak256(abi.encode(PROVIDER_ID, nullifierHash));
            uint64 expiry = claimValidity == 0 ? 0 : uint64(block.timestamp) + claimValidity;
            registry.issue(subject, UNIQUE_HUMAN_WORLDID, expiry);
        }
    }

    // -----------------------------------------------------------------------
    // Governance (shared with the Rarimo path via INullifierBanControl)
    // -----------------------------------------------------------------------
    function setGovernance(address governance_) external onlyOwner {
        governance = governance_;
        emit GovernanceUpdated(governance_);
    }

    /// @notice Wire (or unset) the statements-layer `ClaimsRegistry`. Zero disables issuance —
    ///         the gate then behaves exactly as in Phase 0. The registry must also permission
    ///         this contract as an issuer of `UNIQUE_HUMAN_WORLDID`.
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
    /// @dev World ID nullifiers are `uint256`; governance passes them as `bytes32`.
    function setNullifierBanned(bytes32 nullifier, bool banned) external override onlyGovernance {
        bannedNullifiers[uint256(nullifier)] = banned;
    }

    /// @notice The fixed external-nullifier scope (exposed for clients/tests).
    function externalNullifierHash() external view returns (uint256) {
        return externalNullifier;
    }
}
