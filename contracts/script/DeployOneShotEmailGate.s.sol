// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {OneShotEmailGate} from "../src/phase3/OneShotEmailGate.sol";
import {DKIMKeyRegistry} from "../src/phase3/DKIMKeyRegistry.sol";
import {IHonkVerifier} from "../src/phase3/interfaces/IHonkVerifier.sol";

/// @notice Deploys the one-shot (non-persistent) email path (docs/AGGREGATED_PROOFS_DESIGN.md 0.5):
///         a `OneShotEmailGate` wired to the Circuit-C(one-shot) verifier + the existing
///         `DKIMKeyRegistry`, then registers the signing key (Amazon SES) and the event statement.
///         Run after `bb contract` -> deploy the OneShotEmailVerifier.
///
/// Values come straight from `nargo execute` over a real Luma email (normalized mod p):
///   ONESHOT_VERIFIER (required)                 — deployed Circuit-C(one-shot) UltraHonk verifier
///   DKIM_KEY_HASH0 / DKIM_KEY_HASH1 (required)  — key_hash_0 / key_hash_1 (Amazon SES live key)
///   EVENT_ID_HASH   (required)                  — event_id (commits to From + event name)
///   DKIM_KEY_REGISTRY (0x7E13…7F66 — WC Sepolia)— reuse the existing registry (broadcaster owns it)
///   DOMAIN          ("amazonses.com")           — the SES signing domain (keccak'd on-chain)
///   STATEMENT_ID    (keccak("LUMA_ATTENDEE"))   — MUST equal the id the input generator used
///   OWNER           (broadcaster)
contract DeployOneShotEmailGate is Script {
    address internal constant WC_SEPOLIA_DKIM_KEYS = 0x7E132c95bb1ee268271b6BE44271808072Bd7F66;

    function run() external {
        address verifier = vm.envAddress("ONESHOT_VERIFIER");
        bytes32 keyHash0 = vm.envBytes32("DKIM_KEY_HASH0");
        bytes32 keyHash1 = vm.envBytes32("DKIM_KEY_HASH1");
        uint256 eventIdHash = vm.envUint("EVENT_ID_HASH");
        address dkimKeysAddr = vm.envOr("DKIM_KEY_REGISTRY", WC_SEPOLIA_DKIM_KEYS);
        address owner = vm.envOr("OWNER", msg.sender);
        bytes32 domain = keccak256(bytes(vm.envOr("DOMAIN", string("amazonses.com"))));
        bytes32 statementId = vm.envOr("STATEMENT_ID", keccak256("LUMA_ATTENDEE"));

        DKIMKeyRegistry dkimKeys = DKIMKeyRegistry(dkimKeysAddr);

        vm.startBroadcast();

        OneShotEmailGate gate = new OneShotEmailGate(owner, IHonkVerifier(verifier), dkimKeys);

        // Register the Amazon SES signing key (broadcaster must own the registry).
        dkimKeys.registerKey(domain, keyHash0, keyHash1);
        // Register the event statement (domain whose key must be valid + the pinned event).
        gate.registerStatement(statementId, domain, eventIdHash);

        vm.stopBroadcast();

        console.log("OneShotEmailGate: ", address(gate));
        console.log("OneShotVerifier:  ", verifier);
        console.log("DKIMKeyRegistry:  ", dkimKeysAddr);
        console.log("domain / statementId / eventIdHash:");
        console.logBytes32(domain);
        console.logBytes32(statementId);
        console.log("  eventIdHash:", eventIdHash);
    }
}
