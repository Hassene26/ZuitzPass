// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ZuitzPassExecutor} from "../src/ZuitzPassExecutor.sol";
import {WorldIDGate} from "../src/WorldIDGate.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";
import {AQueryProofExecutor} from "../src/rarimo/sdk/AQueryProofExecutor.sol";
import {Date2Time} from "../src/rarimo/utils/Date2Time.sol";

import {MockRegistrationSMT, MockQueryVerifier} from "./mocks/RarimoMocks.sol";
import {MockWorldID} from "./mocks/WorldIDMocks.sol";
import {MockClaimsRegistry} from "./mocks/StatementsMocks.sol";

/// @notice Unit coverage for the additive §2.3 issuance hooks on both gates, with the
///         ClaimsRegistry mocked so we assert the exact (subject, claimType, expiry) each gate
///         emits — and that issuance is a no-op when the registry is unset.
contract RarimoIssuanceTest is Test {
    ZuitzPassExecutor internal exec;
    MockRegistrationSMT internal smt;
    MockQueryVerifier internal verifier;
    MockClaimsRegistry internal registry;

    uint256 internal constant EVENT_ID = 0x5a55495450415353;
    bytes32 internal constant ROOT = bytes32(uint256(0xC0FFEE));

    bytes32 internal constant UNIQUE_HUMAN_RARIMO = keccak256("UNIQUE_HUMAN_RARIMO");
    bytes32 internal constant OVER_18 = keccak256("OVER_18");

    uint256 internal currentDate;

    function setUp() public {
        smt = new MockRegistrationSMT();
        verifier = new MockQueryVerifier(true);
        registry = new MockClaimsRegistry();

        exec = new ZuitzPassExecutor();
        exec.initialize(
            ZuitzPassExecutor.InitParams({
                registrationSMT: address(smt),
                verifier: address(verifier),
                owner: address(this),
                eventId: EVENT_ID,
                identityCounterUpperbound: 1,
                timestampUpperbound: 1_800_000_000,
                requireUniqueness: true,
                requireNotExpired: true,
                birthDateUpperbound: 0, // age gate off
                currentDateTimeBound: 0
            })
        );

        currentDate = _asciiDate(30, 1, 1);
        vm.warp(Date2Time.timestampFromDate(currentDate) + 12 hours);
    }

    function test_IssuanceOff_ByDefault() public {
        assertEq(address(exec.claimsRegistry()), address(0));
        exec.execute(ROOT, currentDate, _payload(111), _pts());
        assertTrue(exec.usedNullifiers(bytes32(uint256(111))), "still consumes nullifier");
        assertEq(registry.issueCount(), 0, "no issuance when registry unset");
    }

    function test_IssuesHumanOnly_WhenAgeGateOff() public {
        exec.setClaimsRegistry(address(registry));
        exec.execute(ROOT, currentDate, _payload(111), _pts());

        assertEq(registry.issueCount(), 1, "human only (no age gate)");
        MockClaimsRegistry.Issued memory it = registry.issuedAt(0);
        assertEq(it.subject, keccak256(abi.encode(string("rarimo"), uint256(111))), "subject");
        assertEq(it.claimType, UNIQUE_HUMAN_RARIMO, "UNIQUE_HUMAN_RARIMO");
        assertEq(it.expiresAt, uint64(block.timestamp) + 180 days, "default 180d expiry");
    }

    function test_IssuesOver18_WhenAgeGateOn() public {
        // Enable age gate (birthDateUpperbound != 0) and wire the registry.
        exec.setPolicy(1, 1_800_000_000, true, true, _asciiDate(12, 1, 1), 0);
        exec.setClaimsRegistry(address(registry));

        exec.execute(ROOT, currentDate, _payload(222), _pts());

        assertEq(registry.issueCount(), 2, "human + over18");
        assertEq(registry.issuedAt(0).claimType, UNIQUE_HUMAN_RARIMO, "first = human");
        assertEq(registry.issuedAt(1).claimType, OVER_18, "second = over18");
        assertEq(
            registry.issuedAt(1).subject,
            keccak256(abi.encode(string("rarimo"), uint256(222))),
            "same subject"
        );
    }

    function test_ClaimValidity_Respected() public {
        exec.setClaimsRegistry(address(registry));
        exec.setClaimValidity(30 days);
        exec.execute(ROOT, currentDate, _payload(333), _pts());
        assertEq(registry.issuedAt(0).expiresAt, uint64(block.timestamp) + 30 days, "custom expiry");
    }

    function test_ClaimValidityZero_MeansNeverExpires() public {
        exec.setClaimsRegistry(address(registry));
        exec.setClaimValidity(0);
        exec.execute(ROOT, currentDate, _payload(444), _pts());
        assertEq(registry.issuedAt(0).expiresAt, 0, "0 = never expires");
    }

    // -- helpers --
    function _payload(uint256 nullifier_) internal pure returns (bytes memory) {
        return abi.encode(ZuitzPassExecutor.QueryPayload({nullifier: nullifier_, eventData: 0}));
    }

    function _pts() internal pure returns (AQueryProofExecutor.ProofPoints memory pts) {
        return pts;
    }

    function _asciiDate(uint256 yy, uint256 mm, uint256 dd) internal pure returns (uint256 d) {
        d = (_d(yy / 10) << 40) | (_d(yy % 10) << 32) | (_d(mm / 10) << 24) | (_d(mm % 10) << 16)
            | (_d(dd / 10) << 8) | _d(dd % 10);
    }

    function _d(uint256 n) private pure returns (uint256) {
        return 48 + n;
    }
}

contract WorldIDIssuanceTest is Test {
    WorldIDGate internal gate;
    MockWorldID internal worldId;
    MockClaimsRegistry internal registry;

    address internal constant SIGNAL = address(0xBEEF);
    uint256 internal constant ROOT = 0x1234;
    bytes32 internal constant UNIQUE_HUMAN_WORLDID = keccak256("UNIQUE_HUMAN_WORLDID");

    function setUp() public {
        worldId = new MockWorldID();
        registry = new MockClaimsRegistry();
        gate = new WorldIDGate(IWorldID(address(worldId)), "app_staging_test", "zuitzpass-access");
    }

    function _proof() internal pure returns (uint256[8] memory p) {
        return p;
    }

    function test_IssuanceOff_ByDefault() public {
        assertEq(address(gate.claimsRegistry()), address(0));
        gate.verify(SIGNAL, ROOT, 111, _proof());
        assertTrue(gate.usedNullifiers(111));
        assertEq(registry.issueCount(), 0, "no issuance when registry unset");
    }

    function test_IssuesHuman_WhenRegistrySet() public {
        gate.setClaimsRegistry(address(registry));
        gate.verify(SIGNAL, ROOT, 999, _proof());

        assertEq(registry.issueCount(), 1);
        MockClaimsRegistry.Issued memory it = registry.issuedAt(0);
        assertEq(it.subject, keccak256(abi.encode(string("worldid"), uint256(999))), "subject");
        assertEq(it.claimType, UNIQUE_HUMAN_WORLDID, "UNIQUE_HUMAN_WORLDID");
        assertEq(it.expiresAt, uint64(block.timestamp) + 180 days, "default 180d expiry");
    }

    function test_ClaimValidity_Respected() public {
        gate.setClaimsRegistry(address(registry));
        gate.setClaimValidity(0);
        gate.verify(SIGNAL, ROOT, 1000, _proof());
        assertEq(registry.issuedAt(0).expiresAt, 0, "0 = never expires");
    }
}
