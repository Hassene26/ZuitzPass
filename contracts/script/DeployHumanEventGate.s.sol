// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {HumanEventGate} from "../src/phase3/HumanEventGate.sol";
import {DKIMKeyRegistry} from "../src/phase3/DKIMKeyRegistry.sol";
import {IHonkVerifier} from "../src/phase3/interfaces/IHonkVerifier.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

/// @notice Deploys the CROSS-TYPE gate (docs/AGGREGATED_PROOFS_DESIGN.md §0.5): "a unique human who
///         attended events X..Z". Composes a World ID personhood proof + one Circuit-C(one-shot)
///         email proof per event, all bound to the caller. Reuses the deployed OneShotEmailVerifier
///         and the existing DKIMKeyRegistry (amazonses.com key already registered).
///
/// Env:
///   WORLD_ID_ROUTER  (0x57f9…f611 — WC Sepolia)  — the World ID Router
///   WORLD_ID_APP_ID  (required)                  — MUST equal the frontend's IDKit app_id
///   WORLD_ID_ACTION  ("zuitzpass-access")        — MUST equal the frontend's IDKit action
///   EMAIL_VERIFIER   (0xf75B…86Cf)               — the OneShotEmailVerifier
///   DKIM_KEY_REGISTRY(0x7E13…7F66)
///   EVENT_IDS        (required, comma-separated)  — the required events' event_id (make-eventid.mjs)
///   DOMAIN           ("amazonses.com")
///   STATEMENT_ID     (keccak("HUMAN_AND_LUMA"))
///   OWNER            (broadcaster)
contract DeployHumanEventGate is Script {
    address internal constant WC_SEPOLIA_WORLD_ID_ROUTER = 0x57f928158C3EE7CDad1e4D8642503c4D0201f611;
    address internal constant WC_SEPOLIA_ONESHOT_VERIFIER = 0xf75Bc4576EEE1Fc228993a40394aF5f52c8C86Cf;
    address internal constant WC_SEPOLIA_DKIM_KEYS = 0x7E132c95bb1ee268271b6BE44271808072Bd7F66;

    function run() external {
        address router = vm.envOr("WORLD_ID_ROUTER", WC_SEPOLIA_WORLD_ID_ROUTER);
        string memory appId = vm.envString("WORLD_ID_APP_ID");
        string memory action = vm.envOr("WORLD_ID_ACTION", string("zuitzpass-access"));
        address emailVerifier = vm.envOr("EMAIL_VERIFIER", WC_SEPOLIA_ONESHOT_VERIFIER);
        address dkimKeys = vm.envOr("DKIM_KEY_REGISTRY", WC_SEPOLIA_DKIM_KEYS);
        uint256[] memory eventIds = vm.envUint("EVENT_IDS", ",");
        address owner = vm.envOr("OWNER", msg.sender);
        bytes32 domain = keccak256(bytes(vm.envOr("DOMAIN", string("amazonses.com"))));
        bytes32 statementId = vm.envOr("STATEMENT_ID", keccak256("HUMAN_AND_LUMA"));

        vm.startBroadcast();

        HumanEventGate gate = new HumanEventGate(
            owner, IWorldID(router), appId, action, IHonkVerifier(emailVerifier), DKIMKeyRegistry(dkimKeys)
        );
        gate.registerStatement(statementId, domain, eventIds);

        vm.stopBroadcast();

        console.log("HumanEventGate:", address(gate));
        console.log("worldIdRouter / emailVerifier / dkimKeys:", router, emailVerifier, dkimKeys);
        console.log("externalNullifier:", gate.externalNullifier());
        console.log("statementId:");
        console.logBytes32(statementId);
        console.log("nEvents:", eventIds.length);
    }
}
