// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title DKIMKeyRegistry
/// @notice Governance-managed allowlist of DKIM public keys per sender domain — the one honest
///         trust residue of the trustless email-evidence path (docs/PRIVATE_PROVABILITY_FRAMEWORK.md
///         §B.3): someone must assert what e.g. `lu.ma`'s DNS key is. Keys are identified by the
///         two-field Poseidon hash Circuit C exposes (`RSAPubkey.hash()` → [Field; 2]).
///
///         Rotation model: registering a new key does NOT remove old ones — historical emails stay
///         provable (attendance is a historical fact). A compromised or rotated-out key is cut off
///         with `retireKey(domain, keyId, notAfter)`: proofs under it stop being accepted after the
///         deadline. Retired ≠ deleted; re-registering can lift a retirement.
contract DKIMKeyRegistry is Ownable {
    struct KeyInfo {
        bool registered;
        uint64 notAfter; // 0 = no acceptance deadline
    }

    /// @dev domain (keccak256 of the lowercase domain string) => keyId => info.
    mapping(bytes32 => mapping(bytes32 => KeyInfo)) internal _keys;

    event KeyRegistered(bytes32 indexed domain, bytes32 indexed keyId);
    event KeyRetired(bytes32 indexed domain, bytes32 indexed keyId, uint64 notAfter);

    error KeyNotRegistered(bytes32 domain, bytes32 keyId);

    constructor(address owner_) Ownable(owner_) {}

    /// @notice The registry-side identifier for a circuit key hash pair.
    function keyId(bytes32 keyHash0, bytes32 keyHash1) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(keyHash0, keyHash1));
    }

    /// @notice Allow `domain` proofs under this key (also lifts a previous retirement).
    function registerKey(bytes32 domain, bytes32 keyHash0, bytes32 keyHash1) external onlyOwner {
        bytes32 id = keyId(keyHash0, keyHash1);
        _keys[domain][id] = KeyInfo({registered: true, notAfter: 0});
        emit KeyRegistered(domain, id);
    }

    /// @notice Stop accepting proofs under this key after `notAfter` (pass a past/now timestamp to
    ///         cut it off immediately, e.g. on key compromise).
    function retireKey(bytes32 domain, bytes32 keyHash0, bytes32 keyHash1, uint64 notAfter) external onlyOwner {
        bytes32 id = keyId(keyHash0, keyHash1);
        if (!_keys[domain][id].registered) revert KeyNotRegistered(domain, id);
        _keys[domain][id].notAfter = notAfter;
        emit KeyRetired(domain, id, notAfter);
    }

    /// @notice Whether a proof exposing (keyHash0, keyHash1) is currently acceptable for `domain`.
    function isValidKey(bytes32 domain, bytes32 keyHash0, bytes32 keyHash1) external view returns (bool) {
        KeyInfo storage k = _keys[domain][keyId(keyHash0, keyHash1)];
        if (!k.registered) return false;
        return k.notAfter == 0 || block.timestamp < k.notAfter;
    }
}
