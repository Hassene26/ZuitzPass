// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SparseMerkleTree} from "@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol";
import {SmtFixtureWrapper} from "../test/fixtures/SmtFixtureWrapper.sol";

/// @title GenerateEligibilityFixture
/// @notice Builds a REAL multi-leaf fixture for `eligibility_proof` (Circuit A): one identity
///         (`idc = Poseidon2(secret, 0)`) with N claim leaves coexisting under ONE root, plus
///         decoys for depth. Emits `./eligibility_prover.toml` — copy it to
///         `../eligibility_proof/Prover.toml`, then `nargo execute` there.
///
/// Mirrors the circuit exactly (contracts/PHASE3_UNLINKABLE_DESIGN.md §2/§3):
///   idc        = Poseidon2(secret, 0)
///   leaf_key   = Poseidon2(idc, claimType)
///   leaf_value = Poseidon3(issuerId, expiresAt, 0)          (passed to SMT.add)
///   leaf_hash  = Poseidon3(leaf_key, leaf_value, 1)         (done inside the SMT)
///   nullifier  = Poseidon3(secret, appId, contextId)
///
/// Run (pure computation, no broadcast):
///   forge script script/GenerateEligibilityFixture.s.sol -vvv
///   cp eligibility_prover.toml ../eligibility_proof/Prover.toml
///   (cd ../eligibility_proof && nargo execute)   # success => real conjunction verifies
contract GenerateEligibilityFixture is Script {
    uint32 constant TREE_DEPTH = 20;      // must match the circuit
    uint32 constant MAX_CLAIMS = 4;       // must match the circuit
    uint256 constant N_ACTIVE = 3;        // active claims; slot 3 stays sentinel (0)

    /// @dev BN254 scalar field modulus — claim types are the canonical `keccak256(name) mod p`
    ///      (decision #1), the exact field value the EligibilityGate reduces the statement's
    ///      bytes32 claim types to. Keeps the fixture aligned with the gate end to end.
    uint256 constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // Witness identity + scope.
    uint256 constant SECRET = 424242;
    uint256 constant APP_ID = 0x43414e4e4553;   // "CANNES"
    uint256 constant CONTEXT_ID = 202606;
    uint256 constant NOW_TS = 1790000000;       // < expiries below (not expired)
    uint256 constant SIGNAL = 0;

    function run() external {
        SmtFixtureWrapper smt = new SmtFixtureWrapper(TREE_DEPTH);

        bytes32 idc = smt.poseidon2(bytes32(SECRET), bytes32(0));

        // Active claims: {HUMAN, OVER_18, ATTENDED}. Short ASCII ids (< field modulus).
        uint256[] memory claimTypes = new uint256[](N_ACTIVE);
        uint256[] memory issuers = new uint256[](N_ACTIVE);
        uint256[] memory expiries = new uint256[](N_ACTIVE);
        claimTypes[0] = uint256(keccak256("UNIQUE_HUMAN")) % P;
        claimTypes[1] = uint256(keccak256("OVER_18")) % P;
        claimTypes[2] = uint256(keccak256("ATTENDED_CANNES_2025")) % P;
        issuers[0] = 0x1D;
        issuers[1] = 0x2D;
        issuers[2] = 0x3D;
        expiries[0] = 1798812712;
        expiries[1] = 1798812712;
        expiries[2] = 1798812712;

        // Insert the identity's claim leaves.
        bytes32[] memory leafKeys = new bytes32[](N_ACTIVE);
        for (uint256 i = 0; i < N_ACTIVE; i++) {
            bytes32 key = smt.poseidon2(idc, bytes32(claimTypes[i]));
            bytes32 val = smt.poseidon3(bytes32(issuers[i]), bytes32(expiries[i]), bytes32(0));
            smt.add(key, val);
            leafKeys[i] = key;
        }

        // Decoys so the target leaves sit at real depth with genuine sibling hashes.
        for (uint256 i = 1; i <= 6; i++) {
            bytes32 dKey = smt.poseidon2(bytes32(uint256(0xDEC0) + i), bytes32(0));
            smt.add(dKey, bytes32(uint256(0x1000) + i));
        }

        bytes32 root = smt.getRoot();
        bytes32 nullifier = smt.poseidon3(bytes32(SECRET), bytes32(APP_ID), bytes32(CONTEXT_ID));

        // Gather each active leaf's sibling path (all against the SAME root).
        bytes32[][] memory siblings = new bytes32[][](MAX_CLAIMS);
        for (uint256 i = 0; i < N_ACTIVE; i++) {
            SparseMerkleTree.Proof memory p = smt.getProof(leafKeys[i]);
            require(p.existence, "leaf missing");
            require(p.siblings.length == TREE_DEPTH, "unexpected siblings length");
            siblings[i] = p.siblings;
        }
        siblings[3] = new bytes32[](TREE_DEPTH); // sentinel slot: zeros

        _writeProverToml(root, nullifier, claimTypes, issuers, expiries, siblings);

        console2.log("wrote ./eligibility_prover.toml");
        console2.log("root:", vm.toString(root));
        console2.log("nullifier:", vm.toString(nullifier));
        console2.log("Copy it to ../eligibility_proof/Prover.toml, then: nargo execute");
    }

    function _writeProverToml(
        bytes32 root,
        bytes32 nullifier,
        uint256[] memory claimTypes,
        uint256[] memory issuers,
        uint256[] memory expiries,
        bytes32[][] memory siblings
    ) internal {
        // Scalars (Field = quoted hex; u64 = bare decimal).
        string memory t = string.concat(
            _kv("secret", bytes32(SECRET)), "\n",
            _kv("signal", bytes32(SIGNAL)), "\n",
            _kv("root", root), "\n",
            _kv("nullifier", nullifier), "\n",
            _kv("app_id", bytes32(APP_ID)), "\n",
            _kv("context_id", bytes32(CONTEXT_ID)), "\n",
            "now_ts = ", vm.toString(NOW_TS), "\n"
        );

        // claim_types / issuer_ids: MAX_CLAIMS Field entries (sentinel slots = 0).
        string memory types = "claim_types = [";
        string memory iss = "issuer_ids = [";
        string memory exp = "expires_ats = [";
        for (uint256 i = 0; i < MAX_CLAIMS; i++) {
            bool active = i < claimTypes.length;
            types = string.concat(types, '"', vm.toString(active ? bytes32(claimTypes[i]) : bytes32(0)), '"');
            iss = string.concat(iss, '"', vm.toString(active ? bytes32(issuers[i]) : bytes32(0)), '"');
            exp = string.concat(exp, vm.toString(active ? expiries[i] : uint256(0)));
            if (i + 1 < MAX_CLAIMS) {
                types = string.concat(types, ", ");
                iss = string.concat(iss, ", ");
                exp = string.concat(exp, ", ");
            }
        }
        t = string.concat(t, types, "]\n", iss, "]\n", exp, "]\n");

        // siblings: [[Field; TREE_DEPTH]; MAX_CLAIMS].
        t = string.concat(t, "siblings = [\n");
        for (uint256 i = 0; i < MAX_CLAIMS; i++) {
            t = string.concat(t, "  [");
            for (uint256 j = 0; j < TREE_DEPTH; j++) {
                t = string.concat(t, '"', vm.toString(siblings[i][j]), '"');
                if (j + 1 < TREE_DEPTH) t = string.concat(t, ", ");
            }
            t = string.concat(t, i + 1 < MAX_CLAIMS ? "],\n" : "]\n");
        }
        t = string.concat(t, "]\n");

        vm.writeFile("./eligibility_prover.toml", t);
    }

    function _kv(string memory key, bytes32 val) internal view returns (string memory) {
        return string.concat(key, ' = "', vm.toString(val), '"');
    }
}
