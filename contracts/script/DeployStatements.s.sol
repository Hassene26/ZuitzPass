// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ClaimsRegistry} from "../src/ClaimsRegistry.sol";
import {StatementRegistry} from "../src/StatementRegistry.sol";
import {AttestorIssuer} from "../src/issuers/AttestorIssuer.sol";
import {OnchainReadIssuer} from "../src/issuers/OnchainReadIssuer.sol";
import {ZuitzerlandGovernance} from "../src/ZuitzerlandGovernance.sol";
import {IClaimsRegistry} from "../src/interfaces/IClaimsRegistry.sol";
import {Statement} from "../src/interfaces/IStatementRegistry.sol";

/// @notice Deploys the Phase-1 statements layer (ARCHITECTURE_UPDATED.md §2, §8): the
///         `ClaimsRegistry`, `StatementRegistry`, an `AttestorIssuer`, and a
///         `ZuitzerlandGovernance` wired to drive layer-wide subject bans. Registers the four
///         demo claim types and the §8 "Alps Residency 2026" statement.
///
/// The two provider gates (`ZuitzPassExecutor`, `WorldIDGate`) are permissioned as issuers here
/// (registry side). Each gate's OWNER must still call `gate.setClaimsRegistry(<registry>)` to
/// switch on issuance — that is the gate owner's action, not this script's.
///
/// Env (all optional; defaults in parentheses):
///   OWNER            (broadcaster)  — final owner of the registries/attestor/governance (multisig)
///   RARIMO_GATE      (0x0 — skip)   — ZuitzPassExecutor address to permission as issuer
///   WORLDID_GATE     (0x0 — skip)   — WorldIDGate address to permission as issuer
///   ATTESTOR_SIGNER  (0x0 — skip)   — an initial organizer signer for the AttestorIssuer
///   STATEMENT_ID     (keccak("ALPS_RESIDENCY_2026"))
///   STATEMENT_URI    ("ipfs://alps-residency-2026")
contract DeployStatements is Script {
    // Demo claim types (ARCHITECTURE_UPDATED.md §8 Act 0).
    bytes32 internal constant UNIQUE_HUMAN_RARIMO = keccak256("UNIQUE_HUMAN_RARIMO");
    bytes32 internal constant UNIQUE_HUMAN_WORLDID = keccak256("UNIQUE_HUMAN_WORLDID");
    bytes32 internal constant ZUITZ_MAY25_ATTENDEE = keccak256("ZUITZ_MAY25_ATTENDEE");
    bytes32 internal constant OVER_18 = keccak256("OVER_18");

    function run() external {
        address finalOwner = vm.envOr("OWNER", msg.sender);
        address rarimoGate = vm.envOr("RARIMO_GATE", address(0));
        address worldIdGate = vm.envOr("WORLDID_GATE", address(0));
        address attestorSigner = vm.envOr("ATTESTOR_SIGNER", address(0));
        bytes32 statementId = vm.envOr("STATEMENT_ID", keccak256("ALPS_RESIDENCY_2026"));
        string memory statementURI = vm.envOr("STATEMENT_URI", string("ipfs://alps-residency-2026"));

        vm.startBroadcast();

        // Deploy owned by the broadcaster so this script can wire everything, then hand off.
        ClaimsRegistry claims = new ClaimsRegistry(msg.sender);
        StatementRegistry statements =
            new StatementRegistry(msg.sender, IClaimsRegistry(address(claims)));
        AttestorIssuer attestor = new AttestorIssuer(msg.sender, IClaimsRegistry(address(claims)));
        // Zero-ZK issuer for public on-chain state. Conditions/permissions are app-specific and
        // left to the operator (each claim type it mints must also be permissioned on the registry).
        OnchainReadIssuer onchainReader =
            new OnchainReadIssuer(msg.sender, IClaimsRegistry(address(claims)));

        // Governance wrapper drives layer-wide subject bans through the registry.
        ZuitzerlandGovernance gov = new ZuitzerlandGovernance(address(claims));
        claims.setGovernance(address(gov));

        // Register the four demo claim types.
        claims.registerClaimType(UNIQUE_HUMAN_RARIMO, "ipfs://claim/unique-human-rarimo");
        claims.registerClaimType(UNIQUE_HUMAN_WORLDID, "ipfs://claim/unique-human-worldid");
        claims.registerClaimType(ZUITZ_MAY25_ATTENDEE, "ipfs://claim/zuitz-may25-attendee");
        claims.registerClaimType(OVER_18, "ipfs://claim/over-18");

        // Permission issuers (registry side). One Rarimo passport proof yields personhood + age.
        if (rarimoGate != address(0)) {
            claims.setIssuer(UNIQUE_HUMAN_RARIMO, rarimoGate, true);
            claims.setIssuer(OVER_18, rarimoGate, true);
        }
        if (worldIdGate != address(0)) {
            claims.setIssuer(UNIQUE_HUMAN_WORLDID, worldIdGate, true);
        }
        claims.setIssuer(ZUITZ_MAY25_ATTENDEE, address(attestor), true);
        if (attestorSigner != address(0)) {
            attestor.setSigner(attestorSigner, true);
        }

        // Register the §8 statement: (attendee AND over18) AND (rarimo OR worldid), consumable.
        bytes32[] memory allOf = new bytes32[](2);
        allOf[0] = ZUITZ_MAY25_ATTENDEE;
        allOf[1] = OVER_18;
        bytes32[] memory anyOf = new bytes32[](2);
        anyOf[0] = UNIQUE_HUMAN_RARIMO;
        anyOf[1] = UNIQUE_HUMAN_WORLDID;
        statements.registerStatement(
            statementId,
            Statement({allOf: allOf, anyOf: anyOf, consumable: true, metadataURI: statementURI})
        );

        // Hand off ownership to the multisig if one was supplied.
        if (finalOwner != msg.sender) {
            claims.transferOwnership(finalOwner);
            statements.transferOwnership(finalOwner);
            attestor.transferOwnership(finalOwner);
            onchainReader.transferOwnership(finalOwner);
            gov.transferOwnership(finalOwner);
        }

        vm.stopBroadcast();

        console.log("ClaimsRegistry:       ", address(claims));
        console.log("StatementRegistry:    ", address(statements));
        console.log("AttestorIssuer:       ", address(attestor));
        console.log("OnchainReadIssuer:    ", address(onchainReader));
        console.log("ZuitzerlandGovernance:", address(gov));
        console.log("owner:                ", finalOwner);
    }
}
