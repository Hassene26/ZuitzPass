// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {WorldIDGate} from "../src/WorldIDGate.sol";
import {ZuitzerlandGovernance} from "../src/ZuitzerlandGovernance.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

import {MockWorldID} from "./mocks/WorldIDMocks.sol";

contract WorldIDGateTest is Test {
    WorldIDGate internal gate;
    ZuitzerlandGovernance internal gov;
    MockWorldID internal worldId;

    address internal constant SIGNAL = address(0xBEEF);
    uint256 internal constant ROOT = 0x1234;

    event AccessGranted(address indexed caller, uint256 nullifierHash, address signal);

    function setUp() public {
        worldId = new MockWorldID();
        gate = new WorldIDGate(IWorldID(address(worldId)), "app_staging_test", "zuitzpass-access");
        gov = new ZuitzerlandGovernance(address(gate));
        gate.setGovernance(address(gov));
    }

    function _proof() internal pure returns (uint256[8] memory p) {
        return p; // mock ignores contents
    }

    function test_HappyPath_GrantsAccess() public {
        uint256 nullifier = 111;

        vm.expectEmit(true, false, false, true, address(gate));
        emit AccessGranted(address(this), nullifier, SIGNAL);

        gate.verify(SIGNAL, ROOT, nullifier, _proof());
        assertTrue(gate.usedNullifiers(nullifier));
    }

    function test_DuplicateNullifier_Reverts() public {
        uint256 nullifier = 222;
        gate.verify(SIGNAL, ROOT, nullifier, _proof());

        vm.expectRevert(abi.encodeWithSelector(WorldIDGate.DuplicateNullifier.selector, nullifier));
        gate.verify(SIGNAL, ROOT, nullifier, _proof());
    }

    function test_BannedNullifier_Reverts() public {
        uint256 nullifier = 333;
        gov.banNullifier(bytes32(nullifier));

        vm.expectRevert(WorldIDGate.NullifierBanned.selector);
        gate.verify(SIGNAL, ROOT, nullifier, _proof());
    }

    function test_InvalidProof_Reverts() public {
        worldId.setWillRevert(true);
        vm.expectRevert(bytes("MockWorldID: invalid proof"));
        gate.verify(SIGNAL, ROOT, 444, _proof());
    }

    function test_OnlyGovernanceCanBan() public {
        vm.expectRevert(WorldIDGate.NotGovernance.selector);
        gate.setNullifierBanned(bytes32(uint256(1)), true);
    }

    function test_UnbanRestoresAccess() public {
        uint256 nullifier = 555;
        gov.banNullifier(bytes32(nullifier));
        gov.unbanNullifier(bytes32(nullifier));
        gate.verify(SIGNAL, ROOT, nullifier, _proof());
        assertTrue(gate.usedNullifiers(nullifier));
    }
}
