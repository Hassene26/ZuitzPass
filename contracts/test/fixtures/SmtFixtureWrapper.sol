// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SparseMerkleTree} from "@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol";
import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {PoseidonT4} from "poseidon-solidity/PoseidonT4.sol";

/// @title SmtFixtureWrapper
/// @notice Thin wrapper around dl-solarity's `SparseMerkleTree` (the exact library
///         ERC-7812 uses), configured with **Poseidon** hashers — the same hash the
///         registry sets via setHashers, and the one we confirmed Noir matches.
///
/// @dev Purpose: generate a REAL fixture (root + siblings + key) so we can validate
///      that Circuit 1's `compute_root` reproduces the on-chain root.
///
/// @dev dl-solarity's API (type names, function names) is version-sensitive. If this
///      fails to compile, check the installed solidity-lib version and adjust the type
///      (Bytes32SMT) / calls (initialize, setHashers, add, getProof, getRoot) to match.
///      The poseidon-solidity libs (PoseidonT3/T4) are circomlib-compatible.
contract SmtFixtureWrapper {
    using SparseMerkleTree for SparseMerkleTree.Bytes32SMT;

    SparseMerkleTree.Bytes32SMT internal tree;

    constructor(uint32 maxDepth_) {
        tree.initialize(maxDepth_);
        tree.setHashers(_hash2, _hash3);
    }

    // Poseidon(2) — circomlib-compatible (matches Noir bn254::hash_2).
    function _hash2(bytes32 a_, bytes32 b_) internal pure returns (bytes32) {
        return bytes32(PoseidonT3.hash([uint256(a_), uint256(b_)]));
    }

    // Poseidon(3) — circomlib-compatible (matches Noir bn254::hash_3).
    function _hash3(bytes32 a_, bytes32 b_, bytes32 c_) internal pure returns (bytes32) {
        return bytes32(PoseidonT4.hash([uint256(a_), uint256(b_), uint256(c_)]));
    }

    function add(bytes32 key_, bytes32 value_) external {
        tree.add(key_, value_);
    }

    function getRoot() external view returns (bytes32) {
        return tree.getRoot();
    }

    function getProof(bytes32 key_)
        external
        view
        returns (SparseMerkleTree.Proof memory)
    {
        return tree.getProof(key_);
    }

    // Expose the Poseidon hashers so the generator can compute the isolated key and
    // nullifier with the SAME hash the tree uses.
    function poseidon2(bytes32 a_, bytes32 b_) external pure returns (bytes32) {
        return _hash2(a_, b_);
    }

    function poseidon3(bytes32 a_, bytes32 b_, bytes32 c_) external pure returns (bytes32) {
        return _hash3(a_, b_, c_);
    }
}
