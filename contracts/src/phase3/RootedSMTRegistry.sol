// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SparseMerkleTree} from "@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol";
import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {PoseidonT4} from "poseidon-solidity/PoseidonT4.sol";

/// @title RootedSMTRegistry
/// @notice Shared Phase-3 primitive: a dl-solarity Sparse Merkle Tree (circomlib/iden3 Poseidon —
///         the hash the Noir circuits use) with a **root history + validity window** and a single
///         permissioned `writer`. Both the claims tree (`ClaimsSMTRegistry`) and the per-provider
///         verified-humans tree (`VerifiedHumansTree`) are exactly this shape — a proof is made
///         against a recent root, and the on-chain gate/entrypoint checks it's still fresh.
///
/// @dev Subclasses expose semantic leaf-write functions gated by `onlyWriter` and calling
///      `_insertLeaf` / `_updateLeaf`. The tree is opaque (leaf keys are hashes), so this contract
///      never learns identities.
abstract contract RootedSMTRegistry is Ownable {
    using SparseMerkleTree for SparseMerkleTree.Bytes32SMT;

    SparseMerkleTree.Bytes32SMT internal _tree;

    /// @dev How long a root stays valid after it becomes current (seconds).
    uint256 public rootValidity;
    /// @dev root => unix time produced (0 = never seen).
    mapping(bytes32 => uint256) public rootCreatedAt;
    /// @dev The only address permitted to write leaves.
    address public writer;

    event WriterUpdated(address writer);
    event RootValidityUpdated(uint256 rootValidity);

    error NotWriter();

    constructor(address owner_, uint32 maxDepth_, uint256 rootValidity_) Ownable(owner_) {
        _tree.initialize(maxDepth_);
        _tree.setHashers(_hash2, _hash3);
        rootValidity = rootValidity_ == 0 ? 1 hours : rootValidity_;
    }

    modifier onlyWriter() {
        if (msg.sender != writer) revert NotWriter();
        _;
    }

    function setWriter(address writer_) external onlyOwner {
        _setWriter(writer_);
    }

    function setRootValidity(uint256 rootValidity_) external onlyOwner {
        rootValidity = rootValidity_;
        emit RootValidityUpdated(rootValidity_);
    }

    // -- reads --
    function getRoot() external view returns (bytes32) {
        return _tree.getRoot();
    }

    function isRootValid(bytes32 root) external view returns (bool) {
        uint256 ts = rootCreatedAt[root];
        return ts != 0 && block.timestamp <= ts + rootValidity;
    }

    function getProof(bytes32 key) external view returns (SparseMerkleTree.Proof memory) {
        return _tree.getProof(key);
    }

    // -- internal write helpers (subclasses gate + emit their own semantic events) --
    function _setWriter(address writer_) internal {
        writer = writer_;
        emit WriterUpdated(writer_);
    }

    function _insertLeaf(bytes32 key, bytes32 value) internal returns (bytes32 newRoot) {
        _tree.add(key, value);
        newRoot = _tree.getRoot();
        rootCreatedAt[newRoot] = block.timestamp;
    }

    function _updateLeaf(bytes32 key, bytes32 value) internal returns (bytes32 newRoot) {
        _tree.update(key, value);
        newRoot = _tree.getRoot();
        rootCreatedAt[newRoot] = block.timestamp;
    }

    // -- Poseidon hashers (circomlib/iden3-compatible — match the Noir circuits) --
    function _hash2(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return bytes32(PoseidonT3.hash([uint256(a), uint256(b)]));
    }

    function _hash3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32) {
        return bytes32(PoseidonT4.hash([uint256(a), uint256(b), uint256(c)]));
    }
}
