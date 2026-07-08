// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SparseMerkleTree} from "@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol";
import {SmtFixtureWrapper} from "../test/fixtures/SmtFixtureWrapper.sol";

/// @title GenerateIssuanceFixture
/// @notice Builds a REAL fixture for `issuance_proof` (Circuit B): a verified-humans tree holding a
///         credential `C = Poseidon2(secret, r)` (+ decoys for depth), and emits
///         `./issuance_prover.toml` — copy it to `../issuance_proof/Prover.toml`, then `nargo
///         execute` (and `bb prove/write_vk/write_solidity_verifier --oracle_hash keccak`).
///
/// Mirrors the circuit exactly (contracts/PHASE3_UNLINKABLE_DESIGN.md §4.1):
///   idc              = Poseidon2(secret, 0)
///   C (leaf key)     = Poseidon2(secret, r)          value = 1  -> leaf_hash Poseidon3(C, 1, 1)
///   claim_type       = keccak256("UNIQUE_HUMAN") mod p  (canonical, decision #1)
///   leaf_key         = Poseidon2(idc, claim_type)
///   redeem_nullifier = Poseidon2(r, claim_type)
///
/// Run: forge script script/GenerateIssuanceFixture.s.sol -vvv
contract GenerateIssuanceFixture is Script {
    uint32 constant TREE_DEPTH = 20; // must match the circuit
    uint256 constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    uint256 constant SECRET = 424242;
    uint256 constant R = 987654321;

    function run() external {
        SmtFixtureWrapper smt = new SmtFixtureWrapper(TREE_DEPTH);

        uint256 claimType = uint256(keccak256("UNIQUE_HUMAN")) % P;

        bytes32 idc = smt.poseidon2(bytes32(SECRET), bytes32(0));
        bytes32 commitment = smt.poseidon2(bytes32(SECRET), bytes32(R)); // C
        bytes32 leafKey = smt.poseidon2(idc, bytes32(claimType));
        bytes32 redeemNullifier = smt.poseidon2(bytes32(R), bytes32(claimType));

        // Insert the credential + decoys, ALL with value = 1 to match `VerifiedHumansTree`
        // (so the on-chain tree, seeded with these same keys via `insertCredential`, reproduces
        // this exact `cred_root`). Decoy keys are deterministic — `SeedVerifiedHumans.s.sol`
        // inserts the same set on-chain.
        smt.add(commitment, bytes32(uint256(1)));
        for (uint256 i = 1; i <= 6; i++) {
            smt.add(_decoyKey(smt, i), bytes32(uint256(1)));
        }

        SparseMerkleTree.Proof memory p = smt.getProof(commitment);
        require(p.existence, "credential missing");
        require(p.siblings.length == TREE_DEPTH, "unexpected siblings length");
        bytes32 credRoot = smt.getRoot();

        _writeProverToml(credRoot, bytes32(claimType), leafKey, redeemNullifier, p.siblings);

        console2.log("wrote ./issuance_prover.toml");
        console2.log("cred_root:", vm.toString(credRoot));
        console2.log("leaf_key: ", vm.toString(leafKey));
        console2.log("redeem_nullifier:", vm.toString(redeemNullifier));
        console2.log("Copy to ../issuance_proof/Prover.toml, then: nargo execute");
    }

    function _writeProverToml(
        bytes32 credRoot,
        bytes32 claimType,
        bytes32 leafKey,
        bytes32 redeemNullifier,
        bytes32[] memory siblings
    ) internal {
        string memory t = string.concat(
            _kv("secret", bytes32(SECRET)), "\n",
            _kv("r", bytes32(R)), "\n",
            _kv("cred_root", credRoot), "\n",
            _kv("claim_type", claimType), "\n",
            _kv("leaf_key", leafKey), "\n",
            _kv("redeem_nullifier", redeemNullifier), "\n"
        );

        t = string.concat(t, "siblings = [");
        for (uint256 j = 0; j < siblings.length; j++) {
            t = string.concat(t, '"', vm.toString(siblings[j]), '"');
            if (j + 1 < siblings.length) t = string.concat(t, ", ");
        }
        t = string.concat(t, "]\n");

        vm.writeFile("./issuance_prover.toml", t);
    }

    function _kv(string memory key, bytes32 val) internal view returns (string memory) {
        return string.concat(key, ' = "', vm.toString(val), '"');
    }

    /// @dev Deterministic decoy leaf key i (shared with SeedVerifiedHumans so roots match).
    function _decoyKey(SmtFixtureWrapper smt, uint256 i) internal view returns (bytes32) {
        return smt.poseidon2(bytes32(uint256(0xDEC0) + i), bytes32(0));
    }
}
