// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HonkVerifier} from "../src/phase3/verifier/EligibilityVerifier.sol";

contract DeployEligibilityVerifier is Script {
    function run() external {
        vm.startBroadcast();
        HonkVerifier v = new HonkVerifier();
        vm.stopBroadcast();
        console.log("EligibilityVerifier (HonkVerifier):", address(v));
    }
}
