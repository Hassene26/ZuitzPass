// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {EmailVerifier} from "../src/phase3/verifier/EmailVerifier.sol";

/// @notice Deploys the Circuit-C (email evidence) UltraHonk verifier exported by bb
///         (keccak oracle flavor, 5 public inputs). Its address is the EMAIL_VERIFIER
///         env for `DeployEmailEvidence.s.sol`.
contract DeployEmailVerifier is Script {
    function run() external {
        vm.startBroadcast();
        EmailVerifier v = new EmailVerifier();
        vm.stopBroadcast();
        console.log("EmailVerifier:", address(v));
    }
}
