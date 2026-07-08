// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {EligibilityGate} from "../src/phase3/EligibilityGate.sol";
import {ClaimsSMTRegistry} from "../src/phase3/ClaimsSMTRegistry.sol";
import {StatementRegistry} from "../src/StatementRegistry.sol";
import {IClaimsRegistry} from "../src/interfaces/IClaimsRegistry.sol";
import {IStatementRegistry, Statement} from "../src/interfaces/IStatementRegistry.sol";
import {IEligibilityVerifier} from "../src/phase3/interfaces/IEligibilityVerifier.sol";

import {MockEligibilityVerifier} from "./mocks/EligibilityMocks.sol";

contract EligibilityGateTest is Test {
    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    EligibilityGate internal gate;
    ClaimsSMTRegistry internal claimsSmt;
    StatementRegistry internal statements;
    MockEligibilityVerifier internal verifier;

    bytes32 internal constant HUMAN = keccak256("UNIQUE_HUMAN");
    bytes32 internal constant OVER_18 = keccak256("OVER_18");
    bytes32 internal constant ATTENDED = keccak256("ATTENDED_CANNES_2025");
    bytes32 internal constant STMT = keccak256("CANNES_2026");

    uint256 internal constant CTX = 202606;
    uint256 internal validRoot;

    function setUp() public {
        vm.warp(1_900_000_000); // set time BEFORE producing the root so it's fresh

        claimsSmt = new ClaimsSMTRegistry(address(this), 20, 1 hours);
        claimsSmt.setRedeemer(address(this));
        // Produce a real, fresh root to prove against.
        claimsSmt.addClaimLeaf(bytes32(uint256(0xA11CE)), bytes32(uint256(1)));
        validRoot = uint256(claimsSmt.getRoot());

        statements = new StatementRegistry(address(this), IClaimsRegistry(address(0)));
        statements.registerStatement(STMT, _stmt(_three(HUMAN, OVER_18, ATTENDED), new bytes32[](0), true));

        verifier = new MockEligibilityVerifier();
        gate = new EligibilityGate(
            address(this), IEligibilityVerifier(address(verifier)), claimsSmt, IStatementRegistry(address(statements)), 1 hours
        );
    }

    // Build the 10 public inputs the gate expects, consistent by default.
    function _pub(address app, uint256 nullifier, uint256 signal) internal view returns (bytes32[] memory p) {
        p = new bytes32[](10);
        p[0] = bytes32(validRoot);
        p[1] = bytes32(nullifier);
        p[2] = bytes32(gate.appScope(app, STMT));
        p[3] = bytes32(CTX);
        p[4] = bytes32(block.timestamp);
        p[5] = bytes32(uint256(HUMAN) % P);
        p[6] = bytes32(uint256(OVER_18) % P);
        p[7] = bytes32(uint256(ATTENDED) % P);
        p[8] = bytes32(uint256(0));
        p[9] = bytes32(signal % P);
    }

    function test_Consume_HappyPath() public {
        gate.consume(STMT, CTX, 0, "", _pub(address(this), 111, 0));
        assertTrue(gate.consumedNullifier(111));
    }

    function test_Consume_Replay_Reverts() public {
        bytes32[] memory p = _pub(address(this), 111, 0);
        gate.consume(STMT, CTX, 0, "", p);
        vm.expectRevert(abi.encodeWithSelector(EligibilityGate.AlreadyConsumed.selector, 111));
        gate.consume(STMT, CTX, 0, "", p);
    }

    function test_Consume_DifferentContext_Independent() public {
        gate.consume(STMT, CTX, 0, "", _pub(address(this), 111, 0));
        // A different epoch => a different nullifier (client-side); here we just show a fresh one works.
        gate.consume(STMT, 202607, 0, "", _ctxPub(address(this), 222, 202607));
        assertTrue(gate.consumedNullifier(222));
    }

    function test_Consume_BadProof_Reverts() public {
        bytes32[] memory p = _pub(address(this), 111, 0);
        verifier.setResult(false);
        vm.expectRevert(EligibilityGate.ProofInvalid.selector);
        gate.consume(STMT, CTX, 0, "", p);
    }

    function test_Consume_StaleRoot_Reverts() public {
        bytes32[] memory p = _pub(address(this), 111, 0);
        p[0] = bytes32(uint256(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(EligibilityGate.StaleRoot.selector, bytes32(uint256(0xDEAD))));
        gate.consume(STMT, CTX, 0, "", p);
    }

    function test_Consume_TimeOutOfRange_Reverts() public {
        bytes32[] memory p = _pub(address(this), 111, 0);
        p[4] = bytes32(block.timestamp + 2 hours); // beyond tolerance
        vm.expectRevert();
        gate.consume(STMT, CTX, 0, "", p);
    }

    function test_Consume_ContextMismatch_Reverts() public {
        bytes32[] memory p = _pub(address(this), 111, 0);
        p[3] = bytes32(uint256(999)); // ctx in proof != contextId arg
        vm.expectRevert(abi.encodeWithSelector(EligibilityGate.ContextMismatch.selector, 999, CTX));
        gate.consume(STMT, CTX, 0, "", p);
    }

    function test_Consume_WrongApp_Reverts() public {
        // Proof built for a DIFFERENT app than the caller.
        bytes32[] memory p = _pub(address(0xF00), 111, 0);
        uint256 expected = gate.appScope(address(this), STMT);
        vm.expectRevert(
            abi.encodeWithSelector(EligibilityGate.AppScopeMismatch.selector, gate.appScope(address(0xF00), STMT), expected)
        );
        gate.consume(STMT, CTX, 0, "", p);
    }

    function test_Consume_WrongClaimTypes_Reverts() public {
        bytes32[] memory p = _pub(address(this), 111, 0);
        p[6] = bytes32(uint256(12345)); // tamper OVER_18 slot
        vm.expectRevert(
            abi.encodeWithSelector(EligibilityGate.ClaimTypeMismatch.selector, 1, uint256(12345), uint256(OVER_18) % P)
        );
        gate.consume(STMT, CTX, 0, "", p);
    }

    function test_Consume_SignalMismatch_Reverts() public {
        bytes32[] memory p = _pub(address(this), 111, 42); // proof committed signal 42
        vm.expectRevert(abi.encodeWithSelector(EligibilityGate.SignalMismatch.selector, uint256(42), uint256(7)));
        gate.consume(STMT, CTX, 7, "", p); // app expects signal 7
    }

    function test_Consume_AnyOfUnsupported_Reverts() public {
        bytes32 s2 = keccak256("HAS_ANYOF");
        statements.registerStatement(s2, _stmt(_one(HUMAN), _one(OVER_18), true));
        bytes32[] memory p = _pub(address(this), 111, 0);
        // point the app_id + claim types at s2
        p[2] = bytes32(gate.appScope(address(this), s2));
        vm.expectRevert(EligibilityGate.AnyOfUnsupported.selector);
        gate.consume(s2, CTX, 0, "", p);
    }

    // --- helpers ---
    function _ctxPub(address app, uint256 nullifier, uint256 ctx) internal view returns (bytes32[] memory p) {
        p = _pub(app, nullifier, 0);
        p[3] = bytes32(ctx);
    }

    function _stmt(bytes32[] memory allOf_, bytes32[] memory anyOf_, bool consumable_)
        internal
        pure
        returns (Statement memory)
    {
        return Statement({allOf: allOf_, anyOf: anyOf_, consumable: consumable_, metadataURI: ""});
    }

    function _one(bytes32 a) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = a;
    }

    function _three(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }
}
