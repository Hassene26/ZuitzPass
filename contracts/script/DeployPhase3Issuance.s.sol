// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {VerifiedHumansTree} from "../src/phase3/VerifiedHumansTree.sol";
import {RedeemIssuer} from "../src/phase3/RedeemIssuer.sol";
import {ClaimsSMTRegistry} from "../src/phase3/ClaimsSMTRegistry.sol";
import {IHonkVerifier} from "../src/phase3/interfaces/IHonkVerifier.sol";

/// @notice Deploys the Phase-3 Part-B (issuance) stack — a `VerifiedHumansTree` + `RedeemIssuer` —
///         and wires it to the already-deployed `ClaimsSMTRegistry` and the Circuit-B verifier.
///         Registers one provider. Run after deploying the issuance verifier (bb, keccak flavor).
///
/// ⚠️ This repoints the claims tree's `redeemer` to the new `RedeemIssuer` — claim leaves then land
///    ONLY through the private redeem flow (which is the point). The broadcaster must own the
///    claims tree.
///
/// Env:
///   ISSUANCE_VERIFIER (required)                        — deployed Circuit-B UltraHonk verifier
///   CLAIMS_SMT        (0xED95…9283 — WC Sepolia)        — the deployed ClaimsSMTRegistry
///   OWNER             (broadcaster)                     — governance for the Part-B contracts
///   CRED_TREE_WRITER  (broadcaster)                     — Part-A inserter (provider gate / helper)
///   PROVIDER_ID       (keccak("worldid"))
///   CLAIM_TYPE        (keccak("UNIQUE_HUMAN") mod p)     — canonical field value
///   ISSUER_ID         (1)
///   MAX_VALIDITY      (180 days)
///   TREE_DEPTH        (20)                              — MUST equal the circuit
///   ROOT_VALIDITY     (3600)                            — verified-humans root freshness window
contract DeployPhase3Issuance is Script {
    address internal constant WC_SEPOLIA_CLAIMS_SMT = 0xED95aCC61243503144D3C17AC130f3051CE99283;
    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function run() external {
        address verifier = vm.envAddress("ISSUANCE_VERIFIER");
        address claimsSmtAddr = vm.envOr("CLAIMS_SMT", WC_SEPOLIA_CLAIMS_SMT);
        address owner = vm.envOr("OWNER", msg.sender);
        address credTreeWriter = vm.envOr("CRED_TREE_WRITER", msg.sender);
        bytes32 providerId = vm.envOr("PROVIDER_ID", keccak256("worldid"));
        uint256 claimType = vm.envOr("CLAIM_TYPE", uint256(keccak256("UNIQUE_HUMAN")) % P);
        uint256 issuerId = vm.envOr("ISSUER_ID", uint256(1));
        uint256 maxValidity = vm.envOr("MAX_VALIDITY", uint256(180 days));
        uint32 treeDepth = uint32(vm.envOr("TREE_DEPTH", uint256(20)));
        uint256 rootValidity = vm.envOr("ROOT_VALIDITY", uint256(1 hours));

        ClaimsSMTRegistry claimsSmt = ClaimsSMTRegistry(claimsSmtAddr);

        vm.startBroadcast();

        // Part-A anonymity-set tree (writer = the inserter).
        VerifiedHumansTree credTree = new VerifiedHumansTree(msg.sender, treeDepth, rootValidity);
        credTree.setWriter(credTreeWriter);

        // Part-B entrypoint.
        RedeemIssuer redeemIssuer = new RedeemIssuer(owner, IHonkVerifier(verifier), claimsSmt, maxValidity);

        // Claim leaves now flow only through the redeem entrypoint.
        claimsSmt.setRedeemer(address(redeemIssuer));

        // Register the provider (credential tree + the one claim type it may mint).
        redeemIssuer.registerProvider(providerId, credTree, claimType, issuerId);

        if (owner != msg.sender) {
            credTree.transferOwnership(owner);
        }

        vm.stopBroadcast();

        console.log("VerifiedHumansTree:", address(credTree));
        console.log("RedeemIssuer:      ", address(redeemIssuer));
        console.log("IssuanceVerifier:  ", verifier);
        console.log("ClaimsSMTRegistry: ", claimsSmtAddr, "(redeemer -> RedeemIssuer)");
        console.log("credTree writer:   ", credTreeWriter);
        console.log("providerId / claimType / issuerId:");
        console.logBytes32(providerId);
        console.log("  claimType:", claimType);
        console.log("  issuerId: ", issuerId);
    }
}
