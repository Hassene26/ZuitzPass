// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {SubsidyPool} from "../src/demo/SubsidyPool.sol";
import {IStatementRegistry} from "../src/interfaces/IStatementRegistry.sol";

/// @notice Deploys the §8 demo consumer: a `SubsidyPool` gated on an already-registered statement.
///         This is what an event organizer runs — it needs only the StatementRegistry address and
///         the statement id; it never touches issuers or ZK.
///
/// Env:
///   STATEMENT_REGISTRY (required)                          — the deployed StatementRegistry
///   STATEMENT_ID       (keccak("ALPS_RESIDENCY_2026"))     — the access rule to gate on
///   PAYOUT_AMOUNT      (0.01 ether)                         — wei paid per successful claim
///   EPOCH_LENGTH       (2592000 = 30 days)                  — claim epoch in seconds
///   OWNER              (broadcaster)                        — pool admin (organizers)
///   FUND_AMOUNT        (0)                                  — wei to seed the pool on deploy
contract DeploySubsidyPool is Script {
    function run() external {
        address registry = vm.envAddress("STATEMENT_REGISTRY");
        bytes32 statementId = vm.envOr("STATEMENT_ID", keccak256("ALPS_RESIDENCY_2026"));
        uint256 payoutAmount = vm.envOr("PAYOUT_AMOUNT", uint256(0.01 ether));
        uint256 epochLength = vm.envOr("EPOCH_LENGTH", uint256(30 days));
        address owner = vm.envOr("OWNER", msg.sender);
        uint256 fundAmount = vm.envOr("FUND_AMOUNT", uint256(0));

        vm.startBroadcast();

        SubsidyPool pool = new SubsidyPool(
            owner, IStatementRegistry(registry), statementId, payoutAmount, epochLength
        );
        if (fundAmount != 0) {
            pool.fund{value: fundAmount}();
        }

        vm.stopBroadcast();

        console.log("SubsidyPool:      ", address(pool));
        console.log("StatementRegistry:", registry);
        console.log("payoutAmount:     ", payoutAmount);
        console.log("epochLength:      ", epochLength);
        console.log("funded:           ", fundAmount);
    }
}
