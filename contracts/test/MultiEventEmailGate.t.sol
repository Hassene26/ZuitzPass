// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MultiEventEmailGate} from "../src/phase3/MultiEventEmailGate.sol";
import {DKIMKeyRegistry} from "../src/phase3/DKIMKeyRegistry.sol";
import {IHonkVerifier} from "../src/phase3/interfaces/IHonkVerifier.sol";

import {MockEligibilityVerifier} from "./mocks/EligibilityMocks.sol";

contract MultiEventEmailGateTest is Test {
    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    MultiEventEmailGate internal gate;
    DKIMKeyRegistry internal keys;
    MockEligibilityVerifier internal verifier;

    bytes32 internal constant STMT = keccak256("LUMA_ATTENDEE_X_AND_Y");
    bytes32 internal constant DOMAIN = keccak256("amazonses.com");
    bytes32 internal constant KH0 = bytes32(uint256(0x11));
    bytes32 internal constant KH1 = bytes32(uint256(0x22));
    uint256 internal constant EVENT_X = 0xE7E27A;
    uint256 internal constant EVENT_Y = 0xE7E27B;
    uint256 internal constant NULLIFIER = 0xBEEF;

    address internal alice = address(0xA11CE);

    function setUp() public {
        verifier = new MockEligibilityVerifier();
        keys = new DKIMKeyRegistry(address(this));
        gate = new MultiEventEmailGate(address(this), IHonkVerifier(address(verifier)), keys);

        keys.registerKey(DOMAIN, KH0, KH1);
        uint256[] memory req = new uint256[](2);
        req[0] = EVENT_X;
        req[1] = EVENT_Y;
        gate.registerStatement(STMT, DOMAIN, req);
    }

    function _scope(address caller, bytes32 statementId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(caller, statementId))) % P;
    }

    // one proof's public inputs: [app_id, context_id, kh0, kh1, event_id, nullifier]
    function _pub(address caller, uint256 ctx, uint256 eventId, uint256 nullifier)
        internal
        pure
        returns (bytes32[] memory p)
    {
        p = new bytes32[](6);
        p[0] = bytes32(_scope(caller, STMT));
        p[1] = bytes32(ctx);
        p[2] = KH0;
        p[3] = KH1;
        p[4] = bytes32(eventId);
        p[5] = bytes32(nullifier);
    }

    // Two proofs (event X + event Y) from the SAME person (shared nullifier), covering the set.
    function _bundle(address caller, uint256 ctx, uint256 nul)
        internal
        pure
        returns (bytes[] memory proofs, bytes32[][] memory pubs)
    {
        proofs = new bytes[](2);
        proofs[0] = "";
        proofs[1] = "";
        pubs = new bytes32[][](2);
        pubs[0] = _pub(caller, ctx, EVENT_X, nul);
        pubs[1] = _pub(caller, ctx, EVENT_Y, nul);
    }

    function test_Present_Conjunction_Succeeds() public {
        (bytes[] memory proofs, bytes32[][] memory pubs) = _bundle(alice, 1, NULLIFIER);
        vm.prank(alice);
        gate.present(STMT, 1, proofs, pubs);
        assertTrue(gate.isPresented(NULLIFIER), "shared nullifier consumed");
    }

    function test_Present_OrderInsensitive() public {
        // Y then X still covers the set.
        bytes[] memory proofs = new bytes[](2);
        bytes32[][] memory pubs = new bytes32[][](2);
        pubs[0] = _pub(alice, 1, EVENT_Y, NULLIFIER);
        pubs[1] = _pub(alice, 1, EVENT_X, NULLIFIER);
        vm.prank(alice);
        gate.present(STMT, 1, proofs, pubs);
        assertTrue(gate.isPresented(NULLIFIER));
    }

    function test_Present_MissingEvent_Reverts() public {
        // Two proofs but both for event X -> event Y never covered.
        bytes[] memory proofs = new bytes[](2);
        bytes32[][] memory pubs = new bytes32[][](2);
        pubs[0] = _pub(alice, 1, EVENT_X, NULLIFIER);
        pubs[1] = _pub(alice, 1, EVENT_X, NULLIFIER); // duplicate; Y missing
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiEventEmailGate.EventNotCovered.selector, 1, EVENT_X));
        gate.present(STMT, 1, proofs, pubs);
    }

    function test_Present_DifferentPeople_Reverts() public {
        // Proof X from Alice (nullifier N) + proof Y with a DIFFERENT nullifier -> can't pool.
        bytes[] memory proofs = new bytes[](2);
        bytes32[][] memory pubs = new bytes32[][](2);
        pubs[0] = _pub(alice, 1, EVENT_X, NULLIFIER);
        pubs[1] = _pub(alice, 1, EVENT_Y, 0xF00D); // different person
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiEventEmailGate.NullifierMismatch.selector, 1));
        gate.present(STMT, 1, proofs, pubs);
    }

    function test_Present_WrongProofCount_Reverts() public {
        bytes[] memory proofs = new bytes[](1);
        bytes32[][] memory pubs = new bytes32[][](1);
        pubs[0] = _pub(alice, 1, EVENT_X, NULLIFIER);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiEventEmailGate.WrongProofCount.selector, 1, 2));
        gate.present(STMT, 1, proofs, pubs);
    }

    function test_Present_StolenProof_Reverts() public {
        // Bob presents Alice's bundle -> app_id bound to Alice, Bob's appScope differs.
        (bytes[] memory proofs, bytes32[][] memory pubs) = _bundle(alice, 1, NULLIFIER);
        address bob = address(0xB0B);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(MultiEventEmailGate.AppScopeMismatch.selector, 0, _scope(alice, STMT), _scope(bob, STMT))
        );
        gate.present(STMT, 1, proofs, pubs);
    }

    function test_Present_Replay_Reverts() public {
        (bytes[] memory proofs, bytes32[][] memory pubs) = _bundle(alice, 1, NULLIFIER);
        vm.prank(alice);
        gate.present(STMT, 1, proofs, pubs);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiEventEmailGate.AlreadyPresented.selector, NULLIFIER));
        gate.present(STMT, 1, proofs, pubs);
    }

    function test_Present_BadProof_Reverts() public {
        (bytes[] memory proofs, bytes32[][] memory pubs) = _bundle(alice, 1, NULLIFIER);
        verifier.setResult(false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiEventEmailGate.ProofInvalid.selector, 0));
        gate.present(STMT, 1, proofs, pubs);
    }

    function test_Present_UnknownKey_Reverts() public {
        bytes[] memory proofs = new bytes[](2);
        bytes32[][] memory pubs = new bytes32[][](2);
        pubs[0] = _pub(alice, 1, EVENT_X, NULLIFIER);
        pubs[1] = _pub(alice, 1, EVENT_Y, NULLIFIER);
        pubs[1][2] = bytes32(uint256(0x99)); // unregistered key on the 2nd proof
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MultiEventEmailGate.UnknownDkimKey.selector, 1, DOMAIN, bytes32(uint256(0x99)), KH1)
        );
        gate.present(STMT, 1, proofs, pubs);
    }
}
