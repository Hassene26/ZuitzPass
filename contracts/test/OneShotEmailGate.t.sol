// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {OneShotEmailGate} from "../src/phase3/OneShotEmailGate.sol";
import {DKIMKeyRegistry} from "../src/phase3/DKIMKeyRegistry.sol";
import {IHonkVerifier} from "../src/phase3/interfaces/IHonkVerifier.sol";

import {MockEligibilityVerifier} from "./mocks/EligibilityMocks.sol";

contract OneShotEmailGateTest is Test {
    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    OneShotEmailGate internal gate;
    DKIMKeyRegistry internal keys;
    MockEligibilityVerifier internal verifier;

    bytes32 internal constant STMT = keccak256("LUMA_ATTENDEE_SAFEAI");
    bytes32 internal constant DOMAIN = keccak256("amazonses.com");
    bytes32 internal constant KH0 = bytes32(uint256(0x11));
    bytes32 internal constant KH1 = bytes32(uint256(0x22));
    uint256 internal constant EVENT_ID = 0xE7E27;
    uint256 internal constant NULLIFIER = 0xBEEF;

    address internal alice = address(0xA11CE);

    function setUp() public {
        verifier = new MockEligibilityVerifier();
        keys = new DKIMKeyRegistry(address(this));
        gate = new OneShotEmailGate(address(this), IHonkVerifier(address(verifier)), keys);

        keys.registerKey(DOMAIN, KH0, KH1);
        gate.registerStatement(STMT, DOMAIN, EVENT_ID);
    }

    // Local appScope (calling gate.appScope inline would consume the vm.prank/expectRevert cheat).
    function _scope(address caller, bytes32 statementId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(caller, statementId))) % P;
    }

    // pub: [app_id, context_id, keyHash0, keyHash1, event_id, nullifier]
    function _pub(uint256 appId, uint256 ctx, bytes32 kh0, bytes32 kh1, uint256 eventId, uint256 nullifier)
        internal
        pure
        returns (bytes32[] memory p)
    {
        p = new bytes32[](6);
        p[0] = bytes32(appId);
        p[1] = bytes32(ctx);
        p[2] = kh0;
        p[3] = kh1;
        p[4] = bytes32(eventId);
        p[5] = bytes32(nullifier);
    }

    function _okPub(address caller, uint256 ctx) internal pure returns (bytes32[] memory) {
        return _pub(_scope(caller, STMT), ctx, KH0, KH1, EVENT_ID, NULLIFIER);
    }

    function test_Present_Succeeds() public {
        vm.prank(alice);
        gate.present(STMT, 1, "", _okPub(alice, 1));
        assertTrue(gate.isPresented(NULLIFIER), "nullifier consumed");
    }

    function test_Present_Replay_Reverts() public {
        vm.prank(alice);
        gate.present(STMT, 1, "", _okPub(alice, 1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OneShotEmailGate.AlreadyPresented.selector, NULLIFIER));
        gate.present(STMT, 1, "", _okPub(alice, 1));
    }

    function test_Present_StolenProof_Reverts() public {
        // Alice's proof carries HER app_id; Bob submitting it fails (non-transferable).
        bytes32[] memory aliceProof = _okPub(alice, 1);
        address bob = address(0xB0B);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(OneShotEmailGate.AppScopeMismatch.selector, _scope(alice, STMT), _scope(bob, STMT))
        );
        gate.present(STMT, 1, "", aliceProof);
    }

    function test_Present_WrongContext_Reverts() public {
        // Proof made for context 1, presented under context 2 → mismatch.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OneShotEmailGate.ContextMismatch.selector, 1, 2));
        gate.present(STMT, 2, "", _okPub(alice, 1));
    }

    function test_Present_BadProof_Reverts() public {
        verifier.setResult(false);
        vm.prank(alice);
        vm.expectRevert(OneShotEmailGate.ProofInvalid.selector);
        gate.present(STMT, 1, "", _okPub(alice, 1));
    }

    function test_Present_UnknownKey_Reverts() public {
        bytes32[] memory p = _pub(_scope(alice, STMT), 1, bytes32(uint256(0x99)), KH1, EVENT_ID, NULLIFIER);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(OneShotEmailGate.UnknownDkimKey.selector, DOMAIN, bytes32(uint256(0x99)), KH1)
        );
        gate.present(STMT, 1, "", p);
    }

    function test_Present_WrongEvent_Reverts() public {
        bytes32[] memory p = _pub(_scope(alice, STMT), 1, KH0, KH1, 0xD0D0, NULLIFIER);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OneShotEmailGate.WrongEvent.selector, 0xD0D0, EVENT_ID));
        gate.present(STMT, 1, "", p);
    }

    function test_Present_RetiredKey_Reverts() public {
        keys.retireKey(DOMAIN, KH0, KH1, uint64(block.timestamp)); // immediate cutoff
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OneShotEmailGate.UnknownDkimKey.selector, DOMAIN, KH0, KH1));
        gate.present(STMT, 1, "", _okPub(alice, 1));
    }

    function test_Present_DisabledStatement_Reverts() public {
        gate.setStatementEnabled(STMT, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OneShotEmailGate.StatementNotEnabled.selector, STMT));
        gate.present(STMT, 1, "", _okPub(alice, 1));
    }

    function test_Present_BadPubLength_Reverts() public {
        bytes32[] memory p = new bytes32[](5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OneShotEmailGate.BadPublicInputLength.selector, 5));
        gate.present(STMT, 1, "", p);
    }
}
