// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {MultiEventEmailGate} from "../src/phase3/MultiEventEmailGate.sol";
import {DKIMKeyRegistry} from "../src/phase3/DKIMKeyRegistry.sol";
import {IHonkVerifier} from "../src/phase3/interfaces/IHonkVerifier.sol";

/// @notice Deploys the one-shot COMPOSITION gate (docs/AGGREGATED_PROOFS_DESIGN.md §0.5) and
///         registers a 2-event statement ("attended X AND Y"). Reuses the SAME one-shot Circuit-C
///         verifier and the existing DKIMKeyRegistry (whose amazonses.com key is already registered
///         by the single-event deploy — no new key needed).
///
/// Env:
///   MULTI_VERIFIER   (0xf75B…86Cf)              — the deployed OneShotEmailVerifier (same circuit)
///   DKIM_KEY_REGISTRY(0x7E13…7F66)              — the existing registry (amazonses key already in it)
///   EVENT_ID_X / EVENT_ID_Y (required)          — the two events' event_id (make-eventid.mjs)
///   DOMAIN           ("amazonses.com")
///   STATEMENT_ID     (keccak("LUMA_ATTENDEE_X_AND_Y"))
///   OWNER            (broadcaster)
contract DeployMultiEventGate is Script {
    address internal constant WC_SEPOLIA_ONESHOT_VERIFIER = 0xf75Bc4576EEE1Fc228993a40394aF5f52c8C86Cf;
    address internal constant WC_SEPOLIA_DKIM_KEYS = 0x7E132c95bb1ee268271b6BE44271808072Bd7F66;

    function run() external {
        address verifier = vm.envOr("MULTI_VERIFIER", WC_SEPOLIA_ONESHOT_VERIFIER);
        address dkimKeys = vm.envOr("DKIM_KEY_REGISTRY", WC_SEPOLIA_DKIM_KEYS);
        uint256 eventX = vm.envUint("EVENT_ID_X");
        uint256 eventY = vm.envUint("EVENT_ID_Y");
        address owner = vm.envOr("OWNER", msg.sender);
        bytes32 domain = keccak256(bytes(vm.envOr("DOMAIN", string("amazonses.com"))));
        bytes32 statementId = vm.envOr("STATEMENT_ID", keccak256("LUMA_ATTENDEE_X_AND_Y"));

        uint256[] memory req = new uint256[](2);
        req[0] = eventX;
        req[1] = eventY;

        vm.startBroadcast();

        MultiEventEmailGate gate =
            new MultiEventEmailGate(owner, IHonkVerifier(verifier), DKIMKeyRegistry(dkimKeys));
        gate.registerStatement(statementId, domain, req);

        vm.stopBroadcast();

        console.log("MultiEventEmailGate:", address(gate));
        console.log("verifier / dkimKeys:", verifier, dkimKeys);
        console.log("statementId:");
        console.logBytes32(statementId);
        console.log("requiredEvents: X / Y:");
        console.logBytes32(bytes32(eventX));
        console.logBytes32(bytes32(eventY));
    }
}
