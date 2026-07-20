// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {HumanEventGate} from "../src/phase3/HumanEventGate.sol";
import {DKIMKeyRegistry} from "../src/phase3/DKIMKeyRegistry.sol";
import {IHonkVerifier} from "../src/phase3/interfaces/IHonkVerifier.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

import {MockEligibilityVerifier} from "./mocks/EligibilityMocks.sol";
import {MockWorldID} from "./mocks/WorldIDMocks.sol";

contract HumanEventGateTest is Test {
    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    HumanEventGate internal gate;
    DKIMKeyRegistry internal keys;
    MockEligibilityVerifier internal emailVerifier;
    MockWorldID internal worldId;

    bytes32 internal constant STMT = keccak256("HUMAN_AND_EVENTS");
    bytes32 internal constant DOMAIN = keccak256("amazonses.com");
    bytes32 internal constant KH0 = bytes32(uint256(0x11));
    bytes32 internal constant KH1 = bytes32(uint256(0x22));
    uint256 internal constant EVENT_X = 0xE7E27A;
    uint256 internal constant EVENT_Y = 0xE7E27B;
    uint256 internal constant EMAIL_NUL_X = 0xBEE1;
    uint256 internal constant EMAIL_NUL_Y = 0xBEE2;
    uint256 internal constant HUMAN_NUL = 0x11AA11;

    address internal alice = address(0xA11CE);

    function setUp() public {
        emailVerifier = new MockEligibilityVerifier();
        worldId = new MockWorldID();
        keys = new DKIMKeyRegistry(address(this));
        gate = new HumanEventGate(
            address(this), IWorldID(address(worldId)), "app_staging_x", "zuitzpass-access",
            IHonkVerifier(address(emailVerifier)), keys
        );

        keys.registerKey(DOMAIN, KH0, KH1);
        uint256[] memory req = new uint256[](2);
        req[0] = EVENT_X;
        req[1] = EVENT_Y;
        gate.registerStatement(STMT, DOMAIN, req);
    }

    function _scope(address caller) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(caller, STMT))) % P;
    }

    function _emailPub(address caller, uint256 ctx, uint256 eventId, uint256 nul)
        internal
        pure
        returns (bytes32[] memory p)
    {
        p = new bytes32[](6);
        p[0] = bytes32(_scope(caller));
        p[1] = bytes32(ctx);
        p[2] = KH0;
        p[3] = KH1;
        p[4] = bytes32(eventId);
        p[5] = bytes32(nul);
    }

    function _bundle(address caller, uint256 ctx)
        internal
        pure
        returns (bytes[] memory proofs, bytes32[][] memory pubs)
    {
        proofs = new bytes[](2);
        pubs = new bytes32[][](2);
        pubs[0] = _emailPub(caller, ctx, EVENT_X, EMAIL_NUL_X);
        pubs[1] = _emailPub(caller, ctx, EVENT_Y, EMAIL_NUL_Y);
    }

    function _wid() internal pure returns (HumanEventGate.WorldIDProof memory w) {
        w.root = 0x1234; // placeholder root (MockWorldID ignores it)
        w.nullifierHash = HUMAN_NUL;
        // proof stays zero; MockWorldID ignores it unless willRevert.
    }

    function test_Present_HumanAndEvents_Succeeds() public {
        (bytes[] memory proofs, bytes32[][] memory pubs) = _bundle(alice, 1);
        vm.prank(alice);
        gate.present(STMT, 1, _wid(), proofs, pubs);
        assertTrue(gate.consumedHuman(STMT, 1, HUMAN_NUL), "human nullifier consumed");
        assertTrue(gate.consumedEmailNullifier(EMAIL_NUL_X) && gate.consumedEmailNullifier(EMAIL_NUL_Y), "emails consumed");
    }

    function test_Present_BadWorldIDProof_Reverts() public {
        (bytes[] memory proofs, bytes32[][] memory pubs) = _bundle(alice, 1);
        worldId.setWillRevert(true);
        vm.prank(alice);
        vm.expectRevert(bytes("MockWorldID: invalid proof"));
        gate.present(STMT, 1, _wid(), proofs, pubs);
    }

    function test_Present_HumanReuse_SameContext_Reverts() public {
        (bytes[] memory proofs, bytes32[][] memory pubs) = _bundle(alice, 1);
        vm.prank(alice);
        gate.present(STMT, 1, _wid(), proofs, pubs);
        // Same human (nullifierHash) tries again in the same context -> blocked.
        (bytes[] memory p2, bytes32[][] memory pub2) = _bundle(alice, 1);
        pub2[0][5] = bytes32(uint256(0xCAFE1)); // fresh email nullifiers so we reach the human check
        pub2[1][5] = bytes32(uint256(0xCAFE2));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HumanEventGate.HumanAlreadyUsed.selector, HUMAN_NUL));
        gate.present(STMT, 1, _wid(), p2, pub2);
    }

    function test_Present_HumanReuse_NewContext_Ok() public {
        (bytes[] memory proofs, bytes32[][] memory pubs) = _bundle(alice, 1);
        vm.prank(alice);
        gate.present(STMT, 1, _wid(), proofs, pubs);
        // Different context -> same human may present again (fresh email nullifiers for ctx 2).
        bytes[] memory p2 = new bytes[](2);
        bytes32[][] memory pub2 = new bytes32[][](2);
        pub2[0] = _emailPub(alice, 2, EVENT_X, 0xD1);
        pub2[1] = _emailPub(alice, 2, EVENT_Y, 0xD2);
        vm.prank(alice);
        gate.present(STMT, 2, _wid(), p2, pub2);
        assertTrue(gate.consumedHuman(STMT, 2, HUMAN_NUL));
    }

    function test_Present_MissingEvent_Reverts() public {
        bytes[] memory proofs = new bytes[](2);
        bytes32[][] memory pubs = new bytes32[][](2);
        pubs[0] = _emailPub(alice, 1, EVENT_X, EMAIL_NUL_X);
        pubs[1] = _emailPub(alice, 1, EVENT_X, EMAIL_NUL_Y); // X again; Y missing
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HumanEventGate.EventNotCovered.selector, 1, EVENT_X));
        gate.present(STMT, 1, _wid(), proofs, pubs);
    }

    function test_Present_StolenEmailProof_Reverts() public {
        // Alice's email proofs (app-scoped to Alice) presented by Bob -> AppScopeMismatch.
        (bytes[] memory proofs, bytes32[][] memory pubs) = _bundle(alice, 1);
        address bob = address(0xB0B);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(HumanEventGate.AppScopeMismatch.selector, 0, _scope(alice), _scope(bob))
        );
        gate.present(STMT, 1, _wid(), proofs, pubs);
    }

    function test_Present_BadEmailProof_Reverts() public {
        (bytes[] memory proofs, bytes32[][] memory pubs) = _bundle(alice, 1);
        emailVerifier.setResult(false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HumanEventGate.EmailProofInvalid.selector, 0));
        gate.present(STMT, 1, _wid(), proofs, pubs);
    }

    function test_Present_UnknownKey_Reverts() public {
        (bytes[] memory proofs, bytes32[][] memory pubs) = _bundle(alice, 1);
        pubs[1][2] = bytes32(uint256(0x99)); // unregistered key on the 2nd email
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(HumanEventGate.UnknownDkimKey.selector, 1, DOMAIN, bytes32(uint256(0x99)), KH1)
        );
        gate.present(STMT, 1, _wid(), proofs, pubs);
    }
}
