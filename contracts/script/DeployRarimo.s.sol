// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ZuitzPassExecutor} from "../src/ZuitzPassExecutor.sol";
import {ZuitzerlandGovernance} from "../src/ZuitzerlandGovernance.sol";
import {TD3QueryProofVerifier} from "../src/rarimo/sdk/verifier/TD3QueryProofVerifier.sol";

/// @notice Deploys the Rarimo-path gate (E2E flow Phase 4): the Query-proof verifier (unless
///         one is supplied), the executor, and governance — all wired.
///
/// Defaults target **Rarimo L2** (RPC https://l2.rarimo.com, chainId 7368) where real
/// passports are registered, so a bare `forge script ... --broadcast` just works there.
///
/// Env (all optional; defaults in parentheses):
///   REGISTRATION_SMT   (0x479F84…A879 — live Rarimo L2 RegistrationSMT)
///   QUERY_VERIFIER     (0x0 — when unset, deploys a fresh TD3QueryProofVerifier)
///   EVENT_ID           (0x5a55495450415353 "ZUITPASS" — fixed ZuitzPass scope)
///   OWNER              (broadcaster)
///   ID_COUNTER_MAX     (1)  TIMESTAMP_UPPERBOUND (0 = deploy time; uniqueness cutoff)
///   REQUIRE_UNIQUENESS (true)  REQUIRE_NOT_EXPIRED (true)
///   BIRTHDATE_UPPERBOUND (0 = age gate off)  CURRENT_DATE_TIME_BOUND (86400 = 1 day)
contract DeployRarimo is Script {
    // Live Rarimo L2 RegistrationSMT (verified: getRoot != 0, ROOT_VALIDITY 3600, isRootValid).
    address internal constant RARIMO_L2_REGISTRATION_SMT =
        0x479F84502Db545FA8d2275372E0582425204A879;

    function run() external {
        address registrationSMT = vm.envOr("REGISTRATION_SMT", RARIMO_L2_REGISTRATION_SMT);
        address verifier = vm.envOr("QUERY_VERIFIER", address(0));
        uint256 eventId = vm.envOr("EVENT_ID", uint256(0x5a55495450415353));

        address owner = vm.envOr("OWNER", msg.sender);
        uint256 idCounterMax = vm.envOr("ID_COUNTER_MAX", uint256(1));
        bool requireUniqueness = vm.envOr("REQUIRE_UNIQUENESS", true);
        bool requireNotExpired = vm.envOr("REQUIRE_NOT_EXPIRED", true);
        uint256 birthDateUpperbound = vm.envOr("BIRTHDATE_UPPERBOUND", uint256(0));
        uint256 currentDateTimeBound = vm.envOr("CURRENT_DATE_TIME_BOUND", uint256(1 days));

        vm.startBroadcast();

        // Deploy our own Query-proof verifier if one wasn't supplied. Rarimo publishes no
        // canonical TD3QueryProofVerifier — it's the Groth16 verifier for the Query circuit.
        // ⚠️ Confirm its verification key matches the LIVE production circuit before mainnet.
        if (verifier == address(0)) {
            verifier = address(new TD3QueryProofVerifier());
        }

        ZuitzPassExecutor exec = new ZuitzPassExecutor();
        exec.initialize(
            ZuitzPassExecutor.InitParams({
                registrationSMT: registrationSMT,
                verifier: verifier,
                owner: owner,
                eventId: eventId,
                identityCounterUpperbound: idCounterMax,
                timestampUpperbound: vm.envOr("TIMESTAMP_UPPERBOUND", uint256(0)), // 0 = deploy time
                requireUniqueness: requireUniqueness,
                requireNotExpired: requireNotExpired,
                birthDateUpperbound: birthDateUpperbound,
                currentDateTimeBound: currentDateTimeBound
            })
        );

        ZuitzerlandGovernance gov = new ZuitzerlandGovernance(address(exec));
        exec.setGovernance(address(gov));

        vm.stopBroadcast();

        console.log("TD3QueryProofVerifier:", verifier);
        console.log("ZuitzPassExecutor:    ", address(exec));
        console.log("ZuitzerlandGovernance:", address(gov));
        console.log("registrationSMT:      ", registrationSMT);
    }
}
