// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {ClaimsSMTRegistry} from "../src/phase3/ClaimsSMTRegistry.sol";
import {EligibilityGate} from "../src/phase3/EligibilityGate.sol";
import {IEligibilityVerifier} from "../src/phase3/interfaces/IEligibilityVerifier.sol";
import {IStatementRegistry} from "../src/interfaces/IStatementRegistry.sol";

/// @notice Deploys the Phase-3 (unlinkable) on-chain stack — `ClaimsSMTRegistry` + `EligibilityGate`
///         — and wires them to an already-deployed UltraHonk verifier and StatementRegistry. Deploy
///         the verifier first (see the header of contracts/PHASE3_UNLINKABLE_DESIGN.md / the runbook)
///         and pass its address as `ELIGIBILITY_VERIFIER`.
///
/// Belongs on the hub L2 (the chain that holds the claims SMT + runs the verifier) — for the PoC,
/// World Chain Sepolia, alongside the existing statements layer.
///
/// Env:
///   ELIGIBILITY_VERIFIER (required)                    — deployed bb UltraHonk verifier (keccak flavor)
///   STATEMENT_REGISTRY   (0x9518…8001 — WC Sepolia)    — reuse the deployed StatementRegistry
///   OWNER                (broadcaster)                 — governance for the Phase-3 contracts
///   REDEEMER             (broadcaster)                 — who may write claim leaves (PoC: you;
///                                                        later: the Circuit-B redeem entrypoint)
///   TREE_DEPTH           (20)                          — MUST equal the circuit's TREE_DEPTH
///   ROOT_VALIDITY        (3600)                        — claims-root freshness window (seconds)
///   TIME_TOLERANCE       (3600)                        — allowed now_ts vs block.timestamp skew
contract DeployPhase3 is Script {
    // Existing StatementRegistry on World Chain Sepolia (from the Phase-1 deploy).
    address internal constant WC_SEPOLIA_STATEMENT_REGISTRY = 0x9518201B65b3b9a26a80Cf7605952620C9498001;

    function run() external {
        address verifier = vm.envAddress("ELIGIBILITY_VERIFIER");
        address statementRegistry = vm.envOr("STATEMENT_REGISTRY", WC_SEPOLIA_STATEMENT_REGISTRY);
        address owner = vm.envOr("OWNER", msg.sender);
        address redeemer = vm.envOr("REDEEMER", msg.sender);
        uint32 treeDepth = uint32(vm.envOr("TREE_DEPTH", uint256(20)));
        uint256 rootValidity = vm.envOr("ROOT_VALIDITY", uint256(1 hours));
        uint256 timeTolerance = vm.envOr("TIME_TOLERANCE", uint256(1 hours));

        vm.startBroadcast();

        // Deploy the SMT registry owned by the broadcaster so we can set the redeemer, then hand off.
        ClaimsSMTRegistry claimsSmt = new ClaimsSMTRegistry(msg.sender, treeDepth, rootValidity);
        claimsSmt.setRedeemer(redeemer);

        EligibilityGate gate = new EligibilityGate(
            owner,
            IEligibilityVerifier(verifier),
            claimsSmt,
            IStatementRegistry(statementRegistry),
            timeTolerance
        );

        if (owner != msg.sender) {
            claimsSmt.transferOwnership(owner);
        }

        vm.stopBroadcast();

        console.log("EligibilityVerifier:", verifier);
        console.log("ClaimsSMTRegistry:  ", address(claimsSmt));
        console.log("EligibilityGate:    ", address(gate));
        console.log("StatementRegistry:  ", statementRegistry);
        console.log("redeemer:           ", redeemer);
        console.log("owner:              ", owner);
    }
}
