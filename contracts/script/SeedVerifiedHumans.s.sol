// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {VerifiedHumansTree} from "../src/phase3/VerifiedHumansTree.sol";

/// @notice Seeds the on-chain `VerifiedHumansTree` with the exact credential + decoy leaves the
///         Circuit-B fixture (`GenerateIssuanceFixture`) was built against — so the on-chain
///         `cred_root` equals the fixture's, and the proof verifies. Run by the tree's `writer`.
///
///         Uses the SAME constants as the generator (SECRET, R, decoy keys), all inserted with
///         value = 1 via `insertCredential`. SMT roots are order-independent, so the resulting root
///         is deterministic. Print the root and confirm it matches the fixture's `cred_root`.
///
/// Env: VERIFIED_HUMANS_TREE (required)
contract SeedVerifiedHumans is Script {
    uint256 constant SECRET = 424242;
    uint256 constant R = 987654321;

    function run() external {
        VerifiedHumansTree vht = VerifiedHumansTree(vm.envAddress("VERIFIED_HUMANS_TREE"));

        bytes32 commitment = bytes32(PoseidonT3.hash([SECRET, R])); // C = Poseidon2(secret, r)

        vm.startBroadcast();
        vht.insertCredential(commitment);
        for (uint256 i = 1; i <= 6; i++) {
            vht.insertCredential(bytes32(PoseidonT3.hash([uint256(0xDEC0) + i, uint256(0)])));
        }
        vm.stopBroadcast();

        console.log("seeded VerifiedHumansTree:", address(vht));
        console.log("credential C:", vm.toString(commitment));
        console.log("cred_root (must match the fixture):", vm.toString(vht.getRoot()));
    }
}
