// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {DKIMKeyRegistry} from "../src/phase3/DKIMKeyRegistry.sol";
import {EmailEvidenceVerifier} from "../src/phase3/EmailEvidenceVerifier.sol";
import {VerifiedHumansTree} from "../src/phase3/VerifiedHumansTree.sol";
import {RedeemIssuer} from "../src/phase3/RedeemIssuer.sol";
import {IHonkVerifier} from "../src/phase3/interfaces/IHonkVerifier.sol";

/// @notice Deploys the email-evidence (Circuit C / zk-email) stack — `DKIMKeyRegistry` +
///         `EmailEvidenceVerifier` + one per-event `VerifiedHumansTree` — and registers the
///         event source. Optionally registers the event's provider on the existing
///         `RedeemIssuer` so Part-B redeems can mint `EVENT_ATTENDED_*` claims.
///         Run after deploying the Circuit-C UltraHonk verifier (bb, keccak flavor).
///
/// Env:
///   EMAIL_VERIFIER  (required)                 — deployed Circuit-C UltraHonk verifier
///   DKIM_KEY_HASH0 / DKIM_KEY_HASH1 (required) — pubkey.hash() halves from the circuit output
///   EVENT_ID_HASH   (required)                 — the circuit's event_id for this event token
///   REDEEM_ISSUER   (0xEa23…ae45 — WC Sepolia) — set 0 to skip provider registration
///   OWNER           (broadcaster)              — governance for the new contracts
///   DOMAIN          ("lu.ma")                  — sender domain (keccak'd on-chain)
///   SOURCE_ID       (keccak("luma:evt_cannes2026"))
///   CLAIM_TYPE      (keccak("EVENT_ATTENDED_CANNES2026") mod p)
///   ISSUER_ID       (2)                        — written into the claim leaf value
///   TREE_DEPTH      (20)                       — MUST equal the circuits' TREE_DEPTH
///   ROOT_VALIDITY   (3600)
contract DeployEmailEvidence is Script {
    address internal constant WC_SEPOLIA_REDEEM_ISSUER = 0xEa23848413b452F8be43B51D4eB1437C0C62ae45;
    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    struct Config {
        address emailVerifier;
        bytes32 keyHash0;
        bytes32 keyHash1;
        uint256 eventIdHash;
        address redeemIssuer;
        address owner;
        bytes32 domain;
        bytes32 sourceId;
        uint256 claimType;
        uint256 issuerId;
        uint32 treeDepth;
        uint256 rootValidity;
    }

    function _config() internal view returns (Config memory c) {
        c.emailVerifier = vm.envAddress("EMAIL_VERIFIER");
        c.keyHash0 = vm.envBytes32("DKIM_KEY_HASH0");
        c.keyHash1 = vm.envBytes32("DKIM_KEY_HASH1");
        c.eventIdHash = vm.envUint("EVENT_ID_HASH");
        c.redeemIssuer = vm.envOr("REDEEM_ISSUER", WC_SEPOLIA_REDEEM_ISSUER);
        c.owner = vm.envOr("OWNER", msg.sender);
        c.domain = keccak256(bytes(vm.envOr("DOMAIN", string("lu.ma"))));
        c.sourceId = vm.envOr("SOURCE_ID", keccak256("luma:evt_cannes2026"));
        c.claimType = vm.envOr("CLAIM_TYPE", uint256(keccak256("EVENT_ATTENDED_CANNES2026")) % P);
        c.issuerId = vm.envOr("ISSUER_ID", uint256(2));
        c.treeDepth = uint32(vm.envOr("TREE_DEPTH", uint256(20)));
        c.rootValidity = vm.envOr("ROOT_VALIDITY", uint256(1 hours));
    }

    function run() external {
        Config memory c = _config();

        vm.startBroadcast();

        DKIMKeyRegistry dkimKeys = new DKIMKeyRegistry(msg.sender);
        EmailEvidenceVerifier evidence =
            new EmailEvidenceVerifier(c.owner, IHonkVerifier(c.emailVerifier), dkimKeys);

        // Per-event anonymity-set tree; Part-A writer is the evidence verifier.
        VerifiedHumansTree credTree = new VerifiedHumansTree(msg.sender, c.treeDepth, c.rootValidity);
        credTree.setWriter(address(evidence));

        dkimKeys.registerKey(c.domain, c.keyHash0, c.keyHash1);
        evidence.registerSource(c.sourceId, c.domain, c.eventIdHash, credTree);

        // Part-B wiring: the event source becomes a provider on the existing RedeemIssuer
        // (broadcaster must own it), so Circuit-B redeems mint EVENT_ATTENDED_* leaves.
        if (c.redeemIssuer != address(0)) {
            RedeemIssuer(c.redeemIssuer).registerProvider(c.sourceId, credTree, c.claimType, c.issuerId);
        }

        if (c.owner != msg.sender) {
            dkimKeys.transferOwnership(c.owner);
            credTree.transferOwnership(c.owner);
        }

        vm.stopBroadcast();

        console.log("DKIMKeyRegistry:      ", address(dkimKeys));
        console.log("EmailEvidenceVerifier:", address(evidence));
        console.log("VerifiedHumansTree:   ", address(credTree));
        console.log("EmailVerifier (C):    ", c.emailVerifier);
        console.log("sourceId / domain / eventIdHash / claimType:");
        console.logBytes32(c.sourceId);
        console.logBytes32(c.domain);
        console.log("  eventIdHash:", c.eventIdHash);
        console.log("  claimType:  ", c.claimType);
    }
}
