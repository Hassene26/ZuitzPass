// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice World ID's field-hashing helper (keccak256 shifted to fit the BN254 field).
library ByteHasher {
    /// @dev Hashes `value` into a single BN254 field element.
    function hashToField(bytes memory value) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(value))) >> 8;
    }
}
