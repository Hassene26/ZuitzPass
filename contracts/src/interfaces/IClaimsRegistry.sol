// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {INullifierBanControl} from "./INullifierBanControl.sol";

/// @notice A typed, on-chain fact about a `subject` (a provider-namespaced nullifier),
///         written by a permissioned issuer. This is the layer-1 output of the statements
///         layer (ARCHITECTURE_UPDATED.md §2.1).
struct Claim {
    address issuer; // the issuer that wrote it (address(0) = no claim)
    uint64 issuedAt; // block.timestamp at issuance
    uint64 expiresAt; // 0 = never expires
}

/// @notice The spine of the statements layer: issuers write typed claims keyed by subject,
///         apps read `hasValidClaim`. Extends `INullifierBanControl` so the existing
///         `ZuitzerlandGovernance` can drive layer-wide subject bans unchanged — a ban kills
///         every claim a subject holds at once (ARCHITECTURE_UPDATED.md §2.1, §8 Act 2).
interface IClaimsRegistry is INullifierBanControl {
    // -- governance (owner = multisig) --
    function registerClaimType(bytes32 claimType, string calldata metadataURI) external;
    function setIssuer(bytes32 claimType, address issuer, bool allowed) external;

    // -- issuers (permissioned per claim type) --
    function issue(bytes32 subject, bytes32 claimType, uint64 expiresAt) external;
    function revoke(bytes32 subject, bytes32 claimType) external; // issuer or governance

    // -- anyone --
    function hasValidClaim(bytes32 subject, bytes32 claimType) external view returns (bool);
    function getClaim(bytes32 subject, bytes32 claimType) external view returns (Claim memory);

    // setNullifierBanned(bytes32 subject, bool banned) is inherited from INullifierBanControl.
}
