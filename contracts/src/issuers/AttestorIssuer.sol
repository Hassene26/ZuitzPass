// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IClaimsRegistry} from "../interfaces/IClaimsRegistry.sol";

/// @title AttestorIssuer
/// @notice A zero-ZK issuer (ARCHITECTURE_UPDATED.md §2.4): an owner-managed allowlist of signers
///         attest facts no cryptography can prove — e.g. an event organizer scans a ZuitzPass QR
///         at the reunion desk and their signer calls `attest(subject, ZUITZ_MAY25_ATTENDEE)`
///         (§8 Act 1b). This is how the first design-partner demos ship before any exotic proof
///         system is integrated.
///
/// @dev Deliberately dumb: it holds no policy beyond "is the caller an allowed signer". The
///      `ClaimsRegistry` must permission this contract as an issuer of the relevant claim type
///      (`claims.setIssuer(claimType, address(attestor), true)`); attested claims never expire.
contract AttestorIssuer is Ownable {
    IClaimsRegistry public immutable claims;

    /// @dev Addresses permitted to attest (e.g. the organizers' check-in devices/relayer).
    mapping(address => bool) public isSigner;

    event SignerSet(address indexed signer, bool allowed);
    event Attested(bytes32 indexed subject, bytes32 indexed claimType, address indexed signer);

    error NotSigner(address caller);

    constructor(address owner_, IClaimsRegistry claims_) Ownable(owner_) {
        claims = claims_;
    }

    modifier onlySigner() {
        if (!isSigner[msg.sender]) revert NotSigner(msg.sender);
        _;
    }

    /// @notice Add/remove an authorized attesting signer.
    function setSigner(address signer, bool allowed) external onlyOwner {
        isSigner[signer] = allowed;
        emit SignerSet(signer, allowed);
    }

    /// @notice Attest that `subject` holds `claimType`. Attested claims never expire (expiry 0);
    ///         governance revokes/bans via the registry if needed.
    function attest(bytes32 subject, bytes32 claimType) external onlySigner {
        claims.issue(subject, claimType, 0);
        emit Attested(subject, claimType, msg.sender);
    }
}
