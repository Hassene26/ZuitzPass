// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SparseMerkleTree} from "@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol";
import {SmtFixtureWrapper} from "../test/fixtures/SmtFixtureWrapper.sol";

/// @title GenerateSmtFixture
/// @notice Builds a REAL membership fixture against dl-solarity's SparseMerkleTree
///         (Poseidon hashers) and prints witness/public values ready to paste into
///         `membership_proof/Prover.toml`, plus writes ./smt_fixture.json.
///
/// Mirrors Circuit 1 exactly:
///   commitment = Poseidon2(secret, 0)
///   leaf_key   = getIsolatedKey(registrar, commitment) = Poseidon2(registrar, commitment)
///   nullifier  = Poseidon2(secret, APP_CONTEXT)
///   leaf_hash  = Poseidon3(leaf_key, value, 1)   (done inside the SMT on add)
///
/// Run (pure computation, no broadcast):
///   forge script script/GenerateSmtFixture.s.sol:GenerateSmtFixture -vvv
///
/// Then paste the printed values into membership_proof/Prover.toml and run there:
///   nargo execute
/// Success => Circuit 1's compute_root reproduces the real SMT root (Check 2 done).
contract GenerateSmtFixture is Script {
    // Must match the circuit.
    uint32 constant TREE_DEPTH = 20;
    uint256 constant APP_CONTEXT = 0x5a55495446524c414e44; // "ZUITZERLAND"

    // Sample witness (arbitrary; registrar should be a real one in production).
    uint256 constant SECRET = 424242;
    uint256 constant VALUE = 777;
    uint256 constant SESSION_BINDING = 0xBEEF;
    address constant REGISTRAR = address(0x21C0);

    function run() external {
        SmtFixtureWrapper smt = new SmtFixtureWrapper(TREE_DEPTH);

        bytes32 commitment = smt.poseidon2(bytes32(SECRET), bytes32(0));
        bytes32 registrarField = bytes32(uint256(uint160(REGISTRAR)));
        bytes32 leafKey = smt.poseidon2(registrarField, commitment);
        bytes32 nullifier = smt.poseidon2(bytes32(SECRET), bytes32(APP_CONTEXT));

        smt.add(leafKey, bytes32(VALUE));

        // Insert decoy leaves so the target leaf sits at a real, non-zero depth with
        // genuine sibling hashes — this is what exercises the path direction / sibling
        // ordering in compute_root (a single-leaf tree has all-zero siblings).
        for (uint256 i = 1; i <= 6; i++) {
            bytes32 dKey = smt.poseidon2(bytes32(uint256(0xDEC0) + i), bytes32(0));
            smt.add(dKey, bytes32(uint256(0x1000) + i));
        }

        SparseMerkleTree.Proof memory p = smt.getProof(leafKey);
        bytes32 root = smt.getRoot();

        // ---- Prover.toml ----
        console2.log("# ---- paste into membership_proof/Prover.toml ----");
        console2.log(_kv("secret", bytes32(SECRET)));
        console2.log(_kv("value", bytes32(VALUE)));
        console2.log(_kv("root", root));
        console2.log(_kv("nullifier", nullifier));
        console2.log(_kv("session_binding", bytes32(SESSION_BINDING)));
        console2.log(_kv("registrar", registrarField));
        console2.log(_siblingsLine(p.siblings));

        // ---- JSON ----
        _writeJson(p, root, nullifier, registrarField);

        // ---- diagnostics ----
        console2.log("");
        console2.log("# diagnostics:");
        console2.log("# siblings length:", p.siblings.length);
        console2.log("# proof existence:", p.existence);
        console2.log(string.concat("# leafKey = ", vm.toString(leafKey)));
        console2.log("# If nargo execute fails on the root, the mismatch is the SMT");
        console2.log("# depth / sibling ordering / leaf-hash -> adjust compute_root.");
    }

    // `key = "0x..."` line for Prover.toml (Noir accepts quoted hex for Field).
    function _kv(string memory key, bytes32 val) internal view returns (string memory) {
        return string.concat(key, ' = "', vm.toString(val), '"');
    }

    function _siblingsLine(bytes32[] memory s) internal view returns (string memory) {
        string memory line = "siblings = [";
        for (uint256 i = 0; i < s.length; i++) {
            line = string.concat(line, '"', vm.toString(s[i]), '"');
            if (i + 1 < s.length) line = string.concat(line, ", ");
        }
        return string.concat(line, "]");
    }

    function _writeJson(
        SparseMerkleTree.Proof memory p,
        bytes32 root,
        bytes32 nullifier,
        bytes32 registrarField
    ) internal {
        string memory obj = "fixture";
        vm.serializeBytes32(obj, "secret", bytes32(SECRET));
        vm.serializeBytes32(obj, "value", bytes32(VALUE));
        vm.serializeBytes32(obj, "root", root);
        vm.serializeBytes32(obj, "nullifier", nullifier);
        vm.serializeBytes32(obj, "session_binding", bytes32(SESSION_BINDING));
        vm.serializeBytes32(obj, "registrar", registrarField);
        string memory out = vm.serializeBytes32(obj, "siblings", p.siblings);
        vm.writeJson(out, "./smt_fixture.json");
    }
}
