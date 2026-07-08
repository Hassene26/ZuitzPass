// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {WorldIDGate} from "../src/WorldIDGate.sol";
import {ZuitzerlandGovernance} from "../src/ZuitzerlandGovernance.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

/// @notice Deploys the World ID gate + governance, wired.
///
/// Defaults target **World Chain Sepolia** (chainId 4801) for testing with the World ID
/// simulator (no orb/passport needed).
///
/// Env (optional; defaults in parentheses):
///   WORLD_ID_ROUTER  (0x57f9…F611 — World Chain Sepolia router)
///   APP_ID           ("app_staging_0000000000000000000000000000")
///   ACTION           ("zuitzpass-access")
contract DeployWorldID is Script {
    // World ID routers (from docs.world.org). Testnets verify simulator/staging identities.
    address internal constant WORLDCHAIN_SEPOLIA = 0x57f928158C3EE7CDad1e4D8642503c4D0201f611;
    address internal constant OPTIMISM_SEPOLIA = 0x11cA3127182f7583EfC416a8771BD4d11Fae4334;
    address internal constant BASE_SEPOLIA = 0x42FF98C4E85212a5D31358ACbFe76a621b50fC02;
    address internal constant WORLDCHAIN_MAINNET = 0x17B354dD2595411ff79041f930e491A4Df39A278;

    function run() external {
        address router = vm.envOr("WORLD_ID_ROUTER", WORLDCHAIN_SEPOLIA);
        string memory appId = vm.envOr("APP_ID", string("app_staging_0000000000000000000000000000"));
        string memory action = vm.envOr("ACTION", string("zuitzpass-access"));

        vm.startBroadcast();

        WorldIDGate gate = new WorldIDGate(IWorldID(router), appId, action);
        ZuitzerlandGovernance gov = new ZuitzerlandGovernance(address(gate));
        gate.setGovernance(address(gov));

        vm.stopBroadcast();

        console.log("WorldIDGate:          ", address(gate));
        console.log("ZuitzerlandGovernance:", address(gov));
        console.log("router:               ", router);
    }
}
