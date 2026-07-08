// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {WorldIDGate} from "../src/WorldIDGate.sol";
import {ClaimsRegistry} from "../src/ClaimsRegistry.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

/// @notice Redeploy ONLY the `WorldIDGate` against an already-deployed statements layer, using a
///         REAL World ID staging `appId`. Needed because the gate's `externalNullifier`
///         (derived from `appId` + `action`) is immutable — a gate deployed with the placeholder
///         appId can never verify a real simulator proof. The rest of the stack is untouched;
///         this re-points issuance at the new gate.
///
///         Steps performed (broadcaster must be the ClaimsRegistry owner):
///           1. deploy WorldIDGate(router, APP_ID, ACTION)
///           2. gate.setClaimsRegistry(CLAIMS_REGISTRY)                 — switch issuance on
///           3. claims.setIssuer(UNIQUE_HUMAN_WORLDID, newGate, true)   — permit it to issue
///           4. (optional) claims.setIssuer(UNIQUE_HUMAN_WORLDID, OLD_GATE, false) — revoke old
///
/// Env:
///   CLAIMS_REGISTRY (required)                       — deployed ClaimsRegistry
///   APP_ID          (required)                       — REAL app_staging_... from the portal
///   ACTION          ("zuitzpass-access")             — must match your Incognito Action
///   WORLD_ID_ROUTER (0x57f9…F611 WC Sepolia)
///   OLD_GATE        (0x0 — skip revoke)
///   OWNER           (broadcaster)
contract RedeployWorldIDGate is Script {
    address internal constant WORLDCHAIN_SEPOLIA_ROUTER = 0x57f928158C3EE7CDad1e4D8642503c4D0201f611;
    bytes32 internal constant UNIQUE_HUMAN_WORLDID = keccak256("UNIQUE_HUMAN_WORLDID");

    function run() external {
        ClaimsRegistry claims = ClaimsRegistry(vm.envAddress("CLAIMS_REGISTRY"));
        string memory appId = vm.envString("APP_ID"); // no default: force a real one
        string memory action = vm.envOr("ACTION", string("zuitzpass-access"));
        address router = vm.envOr("WORLD_ID_ROUTER", WORLDCHAIN_SEPOLIA_ROUTER);
        address oldGate = vm.envOr("OLD_GATE", address(0));
        address owner = vm.envOr("OWNER", msg.sender);

        vm.startBroadcast();

        WorldIDGate gate = new WorldIDGate(IWorldID(router), appId, action);
        gate.setClaimsRegistry(address(claims));

        claims.setIssuer(UNIQUE_HUMAN_WORLDID, address(gate), true);
        if (oldGate != address(0)) {
            claims.setIssuer(UNIQUE_HUMAN_WORLDID, oldGate, false);
        }
        if (owner != msg.sender) {
            gate.transferOwnership(owner);
        }

        vm.stopBroadcast();

        console.log("new WorldIDGate:    ", address(gate));
        console.log("externalNullifier:  ", gate.externalNullifierHash());
        console.log("ClaimsRegistry:     ", address(claims));
        console.log("revoked old gate:   ", oldGate);
    }
}
