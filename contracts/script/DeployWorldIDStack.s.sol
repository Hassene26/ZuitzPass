// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {WorldIDGate} from "../src/WorldIDGate.sol";
import {ClaimsRegistry} from "../src/ClaimsRegistry.sol";
import {StatementRegistry} from "../src/StatementRegistry.sol";
import {AttestorIssuer} from "../src/issuers/AttestorIssuer.sol";
import {OnchainReadIssuer} from "../src/issuers/OnchainReadIssuer.sol";
import {ZuitzerlandGovernance} from "../src/ZuitzerlandGovernance.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";
import {IClaimsRegistry} from "../src/interfaces/IClaimsRegistry.sol";
import {IStatementRegistry, Statement} from "../src/interfaces/IStatementRegistry.sol";

/// @notice One-command deploy of the FULL World-ID-backed stack for a testnet bring-up
///         (default: World Chain Sepolia, chainId 4801). Composes the already-validated pieces —
///         `WorldIDGate` (real router) + the Phase-1 statements layer + issuers — and wires every
///         edge, including the two steps a piecemeal deploy leaves manual:
///           - `claims.setIssuer(UNIQUE_HUMAN_WORLDID, gate)`  (registry permits the gate to issue)
///           - `gate.setClaimsRegistry(claims)`                (gate switches issuance ON)
///
///         Registers a launch statement: **attended May-2025 AND unique human (World ID)**, since
///         World ID supplies personhood (not age) and the organizer attests attendance to the same
///         World ID subject. Deploy a `SubsidyPool` for it afterwards with `DeploySubsidyPool`
///         (`STATEMENT_ID` = the id logged below).
///
/// Env (all optional; defaults in parentheses):
///   WORLD_ID_ROUTER  (0x57f9…F611 — World Chain Sepolia router)
///   APP_ID           ("app_staging_0000000000000000000000000000")
///   ACTION           ("zuitzpass-access")
///   OWNER            (broadcaster)  — owner of gate + layer (EOA now, multisig later)
///   ATTESTOR_SIGNER  (broadcaster)  — initial organizer signer
///
/// Run (simulate):  forge script script/DeployWorldIDStack.s.sol --rpc-url $WORLDID_RPC
/// Run (broadcast): add  --broadcast --private-key $PK   (needs testnet ETH)
contract DeployWorldIDStack is Script {
    address internal constant WORLDCHAIN_SEPOLIA_ROUTER = 0x57f928158C3EE7CDad1e4D8642503c4D0201f611;

    bytes32 internal constant UNIQUE_HUMAN_WORLDID = keccak256("UNIQUE_HUMAN_WORLDID");
    bytes32 internal constant ZUITZ_MAY25_ATTENDEE = keccak256("ZUITZ_MAY25_ATTENDEE");
    bytes32 internal constant LAUNCH_STATEMENT = keccak256("ZUITZ_LAUNCH_WORLDID");

    function run() external {
        address router = vm.envOr("WORLD_ID_ROUTER", WORLDCHAIN_SEPOLIA_ROUTER);
        string memory appId = vm.envOr("APP_ID", string("app_staging_0000000000000000000000000000"));
        string memory action = vm.envOr("ACTION", string("zuitzpass-access"));
        address owner = vm.envOr("OWNER", msg.sender);
        address attestorSigner = vm.envOr("ATTESTOR_SIGNER", msg.sender);

        vm.startBroadcast();

        // --- Issuer gate (World ID) ---
        WorldIDGate gate = new WorldIDGate(IWorldID(router), appId, action);

        // --- Statements layer (deployed owned by broadcaster so we can wire, then hand off) ---
        ClaimsRegistry claims = new ClaimsRegistry(msg.sender);
        StatementRegistry statements =
            new StatementRegistry(msg.sender, IClaimsRegistry(address(claims)));
        AttestorIssuer attestor = new AttestorIssuer(msg.sender, IClaimsRegistry(address(claims)));
        OnchainReadIssuer onchain = new OnchainReadIssuer(msg.sender, IClaimsRegistry(address(claims)));
        ZuitzerlandGovernance gov = new ZuitzerlandGovernance(address(claims));
        claims.setGovernance(address(gov));

        // --- Claim types + issuer permissions ---
        claims.registerClaimType(UNIQUE_HUMAN_WORLDID, "ipfs://claim/unique-human-worldid");
        claims.registerClaimType(ZUITZ_MAY25_ATTENDEE, "ipfs://claim/zuitz-may25-attendee");
        claims.setIssuer(UNIQUE_HUMAN_WORLDID, address(gate), true);
        claims.setIssuer(ZUITZ_MAY25_ATTENDEE, address(attestor), true);
        attestor.setSigner(attestorSigner, true);

        // --- Switch gate issuance ON (the step a piecemeal deploy forgets) ---
        gate.setClaimsRegistry(address(claims));

        // --- Launch statement: attended AND unique human (World ID) ---
        bytes32[] memory allOf = new bytes32[](1);
        allOf[0] = ZUITZ_MAY25_ATTENDEE;
        bytes32[] memory anyOf = new bytes32[](1);
        anyOf[0] = UNIQUE_HUMAN_WORLDID;
        statements.registerStatement(
            LAUNCH_STATEMENT,
            Statement({allOf: allOf, anyOf: anyOf, consumable: true, metadataURI: "ipfs://zuitz-launch"})
        );

        // --- Hand off ownership if a separate owner was requested ---
        if (owner != msg.sender) {
            gate.transferOwnership(owner);
            claims.transferOwnership(owner);
            statements.transferOwnership(owner);
            attestor.transferOwnership(owner);
            onchain.transferOwnership(owner);
            gov.transferOwnership(owner);
        }

        vm.stopBroadcast();

        console.log("WorldIDGate:       ", address(gate));
        console.log("ClaimsRegistry:    ", address(claims));
        console.log("StatementRegistry: ", address(statements));
        console.log("AttestorIssuer:    ", address(attestor));
        console.log("OnchainReadIssuer: ", address(onchain));
        console.log("Governance:        ", address(gov));
        console.log("router:            ", router);
        console.log("owner:             ", owner);
        console.log("LAUNCH_STATEMENT id:");
        console.logBytes32(LAUNCH_STATEMENT);
    }
}
