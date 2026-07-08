// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {WorldIDGate} from "../src/WorldIDGate.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

/// @title WorldIDGate — fork test against the REAL World Chain Sepolia router
/// @notice Replays a proof captured from the World ID **simulator** (no orb/passport needed)
///         through our gate + the REAL router. If it passes, the whole ZK path is validated on
///         real infrastructure — the thing the Rarimo path is blocked on.
///
/// Get a proof: https://simulator.worldcoin.org (staging) via IDKit, using the SAME appId +
/// action the fixture sets. See docs/WORLDID_PATH.md.
///
/// Run:
///   PROOF_FIXTURE=test/fixtures/worldid_proof.json FORK=true \
///     forge test --match-test test_RealProof_Replay -vvv
///
/// Skipped unless both FORK and PROOF_FIXTURE are set.
contract WorldIDGateForkTest is Test {
    using stdJson for string;

    // World Chain Sepolia World ID Router (chainId 4801; codesize confirmed live).
    address internal constant WORLD_ID_ROUTER = 0x57f928158C3EE7CDad1e4D8642503c4D0201f611;

    bool internal forking;

    function setUp() public {
        if (!vm.envOr("FORK", false)) return;
        vm.createSelectFork(
            vm.envOr("WORLDID_RPC", string("https://worldchain-sepolia.g.alchemy.com/public"))
        );
        forking = true;
    }

    function test_RouterIsLive() public {
        if (!forking) {
            vm.skip(true);
            return;
        }
        assertGt(WORLD_ID_ROUTER.code.length, 0, "router should be deployed");
    }

    function test_RealProof_Replay() public {
        string memory path = vm.envOr("PROOF_FIXTURE", string(""));
        if (!forking || bytes(path).length == 0) {
            vm.skip(true);
            return;
        }

        string memory j = vm.readFile(path);

        WorldIDGate gate = new WorldIDGate(
            IWorldID(WORLD_ID_ROUTER),
            j.readString(".appId"),
            j.readString(".action")
        );

        address signal = j.readAddress(".signal");
        uint256 root = j.readUint(".root");
        uint256 nullifierHash = j.readUint(".nullifierHash");

        uint256[] memory raw = j.readUintArray(".proof"); // len 8
        uint256[8] memory proof;
        for (uint256 i = 0; i < 8; i++) {
            proof[i] = raw[i];
        }

        gate.verify(signal, root, nullifierHash, proof);
        assertTrue(gate.usedNullifiers(nullifierHash), "real simulator proof should be accepted");
    }
}
