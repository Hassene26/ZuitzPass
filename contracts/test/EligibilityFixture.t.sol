// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SparseMerkleTree} from "@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol";
import {SmtFixtureWrapper} from "./fixtures/SmtFixtureWrapper.sol";

/// @notice Multi-leaf "Check 2" for the eligibility circuit: builds the real dl-solarity SMT the
///         way GenerateEligibilityFixture does (one identity, N claim leaves + decoys), then runs a
///         Solidity port of the circuit's `compute_root` for EACH leaf and asserts it reproduces the
///         real root. If green, `eligibility_proof/src/main.nr`'s reconstruction is faithful to the
///         real SMT for a genuine conjunction — the thing single-leaf tests couldn't cover.
contract EligibilityFixtureTest is Test {
    uint32 constant TREE_DEPTH = 20;
    uint256 constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    SmtFixtureWrapper internal smt;

    uint256 constant SECRET = 424242;

    function setUp() public {
        smt = new SmtFixtureWrapper(TREE_DEPTH);
    }

    function test_CircuitComputeRoot_ReproducesRealRoot_ForEveryClaim() public {
        bytes32 idc = smt.poseidon2(bytes32(SECRET), bytes32(0));

        uint256[3] memory claimTypes = [
            uint256(keccak256("UNIQUE_HUMAN")) % P,
            uint256(keccak256("OVER_18")) % P,
            uint256(keccak256("ATTENDED_CANNES_2025")) % P
        ];
        uint256[3] memory issuers = [uint256(0x1D), 0x2D, 0x3D];
        uint256[3] memory expiries = [uint256(1798812712), 1798812712, 1798812712];

        bytes32[3] memory leafKeys;
        bytes32[3] memory values;
        for (uint256 i = 0; i < 3; i++) {
            leafKeys[i] = smt.poseidon2(idc, bytes32(claimTypes[i]));
            values[i] = smt.poseidon3(bytes32(issuers[i]), bytes32(expiries[i]), bytes32(0));
            smt.add(leafKeys[i], values[i]);
        }
        for (uint256 i = 1; i <= 6; i++) {
            smt.add(smt.poseidon2(bytes32(uint256(0xDEC0) + i), bytes32(0)), bytes32(uint256(0x1000) + i));
        }

        bytes32 root = smt.getRoot();

        for (uint256 i = 0; i < 3; i++) {
            SparseMerkleTree.Proof memory p = smt.getProof(leafKeys[i]);
            assertTrue(p.existence, "leaf must exist");
            // leaf_hash = Poseidon3(leaf_key, value, 1), as the circuit computes it.
            bytes32 leafHash = smt.poseidon3(leafKeys[i], values[i], bytes32(uint256(1)));
            bytes32 recomputed = _computeRoot(leafHash, p.siblings, leafKeys[i]);
            assertEq(recomputed, root, "circuit compute_root must reproduce the real SMT root");
        }
    }

    /// @dev Solidity port of eligibility_proof/src/main.nr `compute_root` (deepest-first,
    ///      trailing-zero-trim, key-bit direction). Must stay byte-identical in logic to the Noir.
    function _computeRoot(bytes32 leafHash, bytes32[] memory siblings, bytes32 leafKey)
        internal
        view
        returns (bytes32)
    {
        bytes32 current = leafHash;
        bool started = false;
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            uint256 sIndex = TREE_DEPTH - 1 - i;
            bytes32 sibling = siblings[sIndex];
            bool active = started || (sibling != bytes32(0));
            bool bit = ((uint256(leafKey) >> sIndex) & 1) == 1; // key_bits[sIndex], LSB indexing
            bytes32 left = bit ? sibling : current;
            bytes32 right = bit ? current : sibling;
            bytes32 combined = smt.poseidon2(left, right);
            current = active ? combined : current;
            started = active;
        }
        return current;
    }
}
