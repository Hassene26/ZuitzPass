// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ClaimsRegistry} from "../src/ClaimsRegistry.sol";
import {StatementRegistry} from "../src/StatementRegistry.sol";
import {AttestorIssuer} from "../src/issuers/AttestorIssuer.sol";
import {ZuitzPassExecutor} from "../src/ZuitzPassExecutor.sol";
import {WorldIDGate} from "../src/WorldIDGate.sol";
import {ZuitzerlandGovernance} from "../src/ZuitzerlandGovernance.sol";
import {IClaimsRegistry} from "../src/interfaces/IClaimsRegistry.sol";
import {Statement} from "../src/interfaces/IStatementRegistry.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";
import {AQueryProofExecutor} from "../src/rarimo/sdk/AQueryProofExecutor.sol";
import {Date2Time} from "../src/rarimo/utils/Date2Time.sol";

import {MockRegistrationSMT, MockQueryVerifier} from "./mocks/RarimoMocks.sol";
import {MockWorldID} from "./mocks/WorldIDMocks.sol";

/// @notice End-to-end integration mirroring ARCHITECTURE_UPDATED.md §8 (Alice + the
///         "Zuitzerland Alps Residency 2026" subsidy pool): a gate verify issues claims, a
///         statement check passes, the pool consumes once, and a second consume in the same
///         epoch reverts. Exercises both issuer gates through the real registries end to end.
contract StatementsIntegrationTest is Test {
    // Layer contracts
    ClaimsRegistry internal claims;
    StatementRegistry internal statements;
    AttestorIssuer internal attestor;
    ZuitzerlandGovernance internal gov;

    // Issuer gates
    ZuitzPassExecutor internal rarimo;
    MockRegistrationSMT internal smt;
    MockQueryVerifier internal rarimoVerifier;
    WorldIDGate internal worldGate;
    MockWorldID internal worldId;

    // Claim types & statement
    bytes32 internal constant UNIQUE_HUMAN_RARIMO = keccak256("UNIQUE_HUMAN_RARIMO");
    bytes32 internal constant UNIQUE_HUMAN_WORLDID = keccak256("UNIQUE_HUMAN_WORLDID");
    bytes32 internal constant ZUITZ_MAY25_ATTENDEE = keccak256("ZUITZ_MAY25_ATTENDEE");
    bytes32 internal constant OVER_18 = keccak256("OVER_18");
    bytes32 internal constant ALPS_RESIDENCY_2026 = keccak256("ALPS_RESIDENCY_2026");

    bytes32 internal constant ROOT = bytes32(uint256(0xC0FFEE));
    uint256 internal constant EVENT_ID = 0x5a55495450415353;
    uint256 internal constant AUGUST = 202608;

    // Actors
    address internal organizerSigner = address(0x012A);
    address internal subsidyPool = address(0x9001);
    uint256 internal aliceRarimoNullifier = 0xA11CE;
    bytes32 internal aliceSubject; // keccak256("rarimo", nullifier)

    uint256 internal currentDate;

    function setUp() public {
        // --- Act 0: layer + gate deployment (governance = this, standing in for the multisig) ---
        claims = new ClaimsRegistry(address(this));
        statements = new StatementRegistry(address(this), IClaimsRegistry(address(claims)));
        attestor = new AttestorIssuer(address(this), IClaimsRegistry(address(claims)));

        gov = new ZuitzerlandGovernance(address(claims));
        claims.setGovernance(address(gov));

        // Rarimo gate (age gate ON so OVER_18 is issued alongside personhood).
        smt = new MockRegistrationSMT();
        rarimoVerifier = new MockQueryVerifier(true);
        rarimo = new ZuitzPassExecutor();
        rarimo.initialize(
            ZuitzPassExecutor.InitParams({
                registrationSMT: address(smt),
                verifier: address(rarimoVerifier),
                owner: address(this),
                eventId: EVENT_ID,
                identityCounterUpperbound: 1,
                timestampUpperbound: 1_800_000_000,
                requireUniqueness: true,
                requireNotExpired: true,
                birthDateUpperbound: _asciiDate(12, 1, 1), // age gate on
                currentDateTimeBound: 0
            })
        );
        rarimo.setClaimsRegistry(address(claims));

        // World ID gate.
        worldId = new MockWorldID();
        worldGate = new WorldIDGate(IWorldID(address(worldId)), "app_staging_test", "zuitzpass-access");
        worldGate.setClaimsRegistry(address(claims));

        // --- Act 0.1: register claim types + permission issuers ---
        claims.registerClaimType(UNIQUE_HUMAN_RARIMO, "");
        claims.registerClaimType(UNIQUE_HUMAN_WORLDID, "");
        claims.registerClaimType(ZUITZ_MAY25_ATTENDEE, "");
        claims.registerClaimType(OVER_18, "");

        claims.setIssuer(UNIQUE_HUMAN_RARIMO, address(rarimo), true);
        claims.setIssuer(OVER_18, address(rarimo), true); // one passport proof yields both
        claims.setIssuer(UNIQUE_HUMAN_WORLDID, address(worldGate), true);
        claims.setIssuer(ZUITZ_MAY25_ATTENDEE, address(attestor), true);

        attestor.setSigner(organizerSigner, true);

        // --- Act 0.2: organizers register their statement ---
        statements.registerStatement(
            ALPS_RESIDENCY_2026,
            Statement({
                allOf: _two(ZUITZ_MAY25_ATTENDEE, OVER_18),
                anyOf: _two(UNIQUE_HUMAN_RARIMO, UNIQUE_HUMAN_WORLDID),
                consumable: true,
                metadataURI: "ipfs://alps-residency-2026"
            })
        );

        aliceSubject = keccak256(abi.encode(string("rarimo"), aliceRarimoNullifier));

        currentDate = _asciiDate(30, 1, 1);
        vm.warp(Date2Time.timestampFromDate(currentDate) + 12 hours);
    }

    function test_Alice_FullFlow() public {
        // --- Act 1a: personhood + age via the Rarimo gate ---
        rarimo.execute(ROOT, currentDate, _rarimoPayload(aliceRarimoNullifier), _pts());
        assertTrue(claims.hasValidClaim(aliceSubject, UNIQUE_HUMAN_RARIMO), "human claim issued");
        assertTrue(claims.hasValidClaim(aliceSubject, OVER_18), "over18 claim issued");

        // Not yet eligible — attendance is still missing.
        assertFalse(statements.check(aliceSubject, ALPS_RESIDENCY_2026), "no attendance yet");

        // --- Act 1b: organizer attests attendance (zero ZK) ---
        vm.prank(organizerSigner);
        attestor.attest(aliceSubject, ZUITZ_MAY25_ATTENDEE);

        // --- Act 2: eligible, pool consumes once ---
        assertTrue(statements.check(aliceSubject, ALPS_RESIDENCY_2026), "now eligible");

        vm.prank(subsidyPool);
        statements.consume(aliceSubject, ALPS_RESIDENCY_2026, AUGUST);
        assertTrue(statements.isConsumed(ALPS_RESIDENCY_2026, subsidyPool, AUGUST, aliceSubject));

        // Second consume in the same epoch reverts.
        vm.prank(subsidyPool);
        vm.expectRevert(
            abi.encodeWithSelector(
                StatementRegistry.AlreadyConsumed.selector,
                ALPS_RESIDENCY_2026,
                subsidyPool,
                AUGUST,
                aliceSubject
            )
        );
        statements.consume(aliceSubject, ALPS_RESIDENCY_2026, AUGUST);

        // September (new epoch) is a fresh context -> allowed again.
        vm.prank(subsidyPool);
        statements.consume(aliceSubject, ALPS_RESIDENCY_2026, 202609);
    }

    function test_WorldIDOnlyFriend_FailsAllOf() public {
        // A friend proves personhood via World ID only — different subject, no attendance/age.
        uint256 friendNullifier = 0xF41E9D;
        bytes32 friendSubject = keccak256(abi.encode(string("worldid"), friendNullifier));

        worldGate.verify(address(0xF), 0x1234, friendNullifier, _emptyProof());
        assertTrue(claims.hasValidClaim(friendSubject, UNIQUE_HUMAN_WORLDID), "worldid claim issued");

        // anyOf is satisfied, but allOf (attendance + over18) is not -> ineligible.
        assertFalse(statements.check(friendSubject, ALPS_RESIDENCY_2026), "fails allOf");
    }

    function test_Ban_RevokesEligibilityEverywhere() public {
        rarimo.execute(ROOT, currentDate, _rarimoPayload(aliceRarimoNullifier), _pts());
        vm.prank(organizerSigner);
        attestor.attest(aliceSubject, ZUITZ_MAY25_ATTENDEE);
        assertTrue(statements.check(aliceSubject, ALPS_RESIDENCY_2026));

        // Governance bans Alice's subject at the layer -> every claim invalidated at once.
        gov.banNullifier(aliceSubject);
        assertFalse(statements.check(aliceSubject, ALPS_RESIDENCY_2026), "ban kills eligibility");

        vm.prank(subsidyPool);
        vm.expectRevert(
            abi.encodeWithSelector(
                StatementRegistry.NotEligible.selector, aliceSubject, ALPS_RESIDENCY_2026
            )
        );
        statements.consume(aliceSubject, ALPS_RESIDENCY_2026, AUGUST);
    }

    // -- helpers --
    function _rarimoPayload(uint256 nullifier_) internal pure returns (bytes memory) {
        return abi.encode(ZuitzPassExecutor.QueryPayload({nullifier: nullifier_, eventData: 0}));
    }

    function _pts() internal pure returns (AQueryProofExecutor.ProofPoints memory pts) {
        return pts;
    }

    function _emptyProof() internal pure returns (uint256[8] memory p) {
        return p;
    }

    function _two(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _asciiDate(uint256 yy, uint256 mm, uint256 dd) internal pure returns (uint256 d) {
        d = (_d(yy / 10) << 40) | (_d(yy % 10) << 32) | (_d(mm / 10) << 24) | (_d(mm % 10) << 16)
            | (_d(dd / 10) << 8) | _d(dd % 10);
    }

    function _d(uint256 n) private pure returns (uint256) {
        return 48 + n;
    }
}
