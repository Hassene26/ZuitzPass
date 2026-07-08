// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {StatementRegistry} from "../src/StatementRegistry.sol";
import {Statement} from "../src/interfaces/IStatementRegistry.sol";

/// @notice Registers the live-demo statement on the deployed `StatementRegistry`:
///         allOf = [UNIQUE_HUMAN], consumable — the rule the eligibility proof satisfies. Run by the
///         StatementRegistry owner (governance). Matches `GenerateEligibilityLiveFixture` (which the
///         gate reduces `keccak(UNIQUE_HUMAN) mod p` to compare against).
///
/// Env: STATEMENT_REGISTRY (0x9518…8001), STATEMENT_ID (keccak("DEMO_HUMAN_ONLY"))
contract RegisterDemoStatement is Script {
    address internal constant WC_SEPOLIA_STATEMENT_REGISTRY = 0x9518201B65b3b9a26a80Cf7605952620C9498001;

    function run() external {
        address reg = vm.envOr("STATEMENT_REGISTRY", WC_SEPOLIA_STATEMENT_REGISTRY);
        bytes32 statementId = vm.envOr("STATEMENT_ID", keccak256("DEMO_HUMAN_ONLY"));

        bytes32[] memory allOf = new bytes32[](1);
        allOf[0] = keccak256("UNIQUE_HUMAN");

        vm.startBroadcast();
        StatementRegistry(reg).registerStatement(
            statementId,
            Statement({allOf: allOf, anyOf: new bytes32[](0), consumable: true, metadataURI: "demo:human-only"})
        );
        vm.stopBroadcast();

        console.log("registered demo statement on:", reg);
        console.logBytes32(statementId);
    }
}
