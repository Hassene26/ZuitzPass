// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ZuitzerlandVerifier} from "../src/ZuitzerlandVerifier.sol";
import {ZuitzerlandGovernance} from "../src/ZuitzerlandGovernance.sol";
import {NoirVerifierWrapper} from "../src/NoirVerifierWrapper.sol";
import {RarimoAdapter} from "../src/adapters/RarimoAdapter.sol";
import {ZkPassportAdapter} from "../src/adapters/ZkPassportAdapter.sol";

/// @title Deploy
/// @notice Deploys + wires the full Zuitzerland stack in the order from
///         ARCHITECTURE.md §8.
///
/// Configure via environment variables (all addresses are chain-specific):
///   EVIDENCE_REGISTRY   - ERC-7812 SINGLETON shared by all providers
///                         (0x781246D2256dc0C1d8357c9dDc1eEe926a9c7812)
///   HONK_VERIFIER       - BB-exported Verifier.sol for Circuit 1
///   RARIMO_REGISTRAR    - Rarimo's registrar contract (the getIsolatedKey source)
///   ZKPASSPORT_REGISTRAR- zkPassport's registrar contract (the getIsolatedKey source)
///   RARIMO_WINDOW       - root validity window for Rarimo (seconds), default 7 days
///   ZKPASSPORT_WINDOW   - root validity window for zkPassport (seconds), default 180 days
///

contract Deploy is Script {
    function run() external {
        // --- config ---
        address evidenceRegistry = vm.envAddress("EVIDENCE_REGISTRY");
        address honkVerifier = vm.envAddress("HONK_VERIFIER");
        address rarimoRegistrar = vm.envAddress("RARIMO_REGISTRAR");
        address zkPassportRegistrar = vm.envAddress("ZKPASSPORT_REGISTRAR");
        uint256 rarimoWindow = vm.envOr("RARIMO_WINDOW", uint256(7 days));
        uint256 zkPassportWindow = vm.envOr("ZKPASSPORT_WINDOW", uint256(180 days));

        vm.startBroadcast();

        // 1. Wrap the real UltraHonk verifier into the INoirVerifier interface.
        NoirVerifierWrapper noir = new NoirVerifierWrapper(honkVerifier);

        // 2. Main verifier.
        ZuitzerlandVerifier verifier =
            new ZuitzerlandVerifier(evidenceRegistry, address(noir));

        // 3. Per-provider adapters (each with its registrar + own freshness window).
        RarimoAdapter rarimo = new RarimoAdapter(rarimoRegistrar, rarimoWindow);
        ZkPassportAdapter zkPassport =
            new ZkPassportAdapter(zkPassportRegistrar, zkPassportWindow);

        // 4. Register adapters.
        verifier.setAdapter(address(rarimo), true);
        verifier.setAdapter(address(zkPassport), true);

        // 5. Governance, then point the verifier at it.
        ZuitzerlandGovernance governance =
            new ZuitzerlandGovernance(address(verifier));
        verifier.setGovernance(address(governance));

        vm.stopBroadcast();

        // --- log deployed addresses ---
        console2.log("NoirVerifierWrapper:   ", address(noir));
        console2.log("ZuitzerlandVerifier:   ", address(verifier));
        console2.log("RarimoAdapter:         ", address(rarimo));
        console2.log("ZkPassportAdapter:     ", address(zkPassport));
        console2.log("ZuitzerlandGovernance: ", address(governance));
    }
}
