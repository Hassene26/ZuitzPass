// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ZuitzPassExecutor} from "../src/ZuitzPassExecutor.sol";
import {AQueryProofExecutor} from "../src/rarimo/sdk/AQueryProofExecutor.sol";
import {PublicSignalsBuilder} from "../src/rarimo/sdk/lib/PublicSignalsBuilder.sol";
import {Date2Time} from "../src/rarimo/utils/Date2Time.sol";
import {TD3QueryProofVerifier} from "../src/rarimo/sdk/verifier/TD3QueryProofVerifier.sol";

import {MockQueryVerifier} from "./mocks/RarimoMocks.sol";

/// @dev The real RegistrationSMT surface (superset of our vendored IPoseidonSMT).
interface IRegistrationSMT {
    function getRoot() external view returns (bytes32);
    function isRootValid(bytes32 root) external view returns (bool);
    function ROOT_VALIDITY() external view returns (uint256);
}

/// @title ZuitzPassExecutor — fork test against the REAL Rarimo L2 registration tree
/// @notice Validates the STATE-dependent path (real root freshness, real block time) against
///         Rarimo L2 mainnet. The ZK math is stood in by `MockQueryVerifier` — a fork copies
///         chain STATE but cannot fabricate a valid proof (that needs a real registered secret).
///         To test the real math too, capture one genuine proof and replay it (see the
///         commented `test_RealProof_Replay` below).
///
/// Run:
///   FORK=true forge test --match-path test/ZuitzPassExecutor.fork.t.sol -vvv
///   (optional) L2_RPC=https://l2.rarimo.com   — defaults to that if unset
///
/// Skipped automatically under a plain `forge test` (no FORK env).
contract ZuitzPassExecutorForkTest is Test {
    using stdJson for string;

    // Live Rarimo L2 RegistrationSMT (chainId 7368).
    address internal constant REG_SMT = 0x479F84502Db545FA8d2275372E0582425204A879;
    uint256 internal constant ZERO_DATE = 0x303030303030;

    ZuitzPassExecutor internal exec;
    MockQueryVerifier internal verifier;
    bool internal forking;
    uint256 internal currentDate;

    function setUp() public {
        if (!vm.envOr("FORK", false)) return;

        vm.createSelectFork(vm.envOr("L2_RPC", string("https://l2.rarimo.com")));
        forking = true;

        verifier = new MockQueryVerifier(true);
        exec = new ZuitzPassExecutor();
        exec.initialize(
            ZuitzPassExecutor.InitParams({
                registrationSMT: REG_SMT,
                verifier: address(verifier),
                owner: address(this),
                eventId: 0x5a55495450415353, // "ZUITPASS"
                identityCounterUpperbound: 1,
                timestampUpperbound: 0, // -> initialize time (forked block)
                requireUniqueness: true,
                requireNotExpired: false, // keep the mock path independent of a real expiry
                birthDateUpperbound: 0,
                currentDateTimeBound: 3650 days // generous: fork block time may lag real "now"
            })
        );

        // Build a currentDate (yyMMdd ASCII) from the forked block's real timestamp.
        (uint256 y, uint256 m, uint256 d) = Date2Time.timestampToDate(block.timestamp);
        currentDate = _asciiDate(y - 2000, m, d);
    }

    /// The real, current root of the live tree must be accepted, and a member let in.
    function test_RealRoot_IsFreshAndGrantsAccess() public {
        if (!forking) {
            vm.skip(true);
            return;
        }

        bytes32 realRoot = IRegistrationSMT(REG_SMT).getRoot();
        assertTrue(realRoot != bytes32(0), "live tree should be populated");
        assertTrue(IRegistrationSMT(REG_SMT).isRootValid(realRoot), "latest real root should be valid");

        uint256 nullifier = 0xABCDEF;
        exec.execute(realRoot, currentDate, _payload(nullifier, uint256(uint160(address(0xBEEF)))), _pts());

        assertTrue(exec.usedNullifiers(bytes32(nullifier)), "nullifier consumed");
    }

    /// An unknown/stale root must be rejected by the REAL tree's isRootValid.
    function test_UnknownRoot_Rejected() public {
        if (!forking) {
            vm.skip(true);
            return;
        }

        bytes32 fakeRoot = keccak256("not-a-real-root");
        assertFalse(IRegistrationSMT(REG_SMT).isRootValid(fakeRoot), "fake root must be invalid on-chain");

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicSignalsBuilder.InvalidRegistrationRoot.selector,
                REG_SMT,
                fakeRoot
            )
        );
        exec.execute(fakeRoot, currentDate, _payload(1, 0), _pts());
    }

    /// Replay ONE captured, genuine RariMe proof through our contract + the REAL Groth16
    /// verifier. This is the ONLY test that confirms the ZK math AND that our
    /// `_buildPublicSignals` (selector bits, criteria, indices) matches the live circuit —
    /// if `execute` succeeds, they agree.
    ///
    /// Provide the proof via a JSON fixture (see test/fixtures/rarimo_proof.example.json and
    /// docs/RARIMO_PATH.md §"Capturing a real proof"):
    ///   PROOF_FIXTURE=test/fixtures/rarimo_proof.json FORK=true \
    ///     forge test --match-test test_RealProof_Replay -vvv
    ///
    /// Skipped unless both FORK and PROOF_FIXTURE are set.
    function test_RealProof_Replay() public {
        string memory path = vm.envOr("PROOF_FIXTURE", string(""));
        if (!forking || bytes(path).length == 0) {
            vm.skip(true);
            return;
        }

        string memory j = vm.readFile(path);

        // Real Groth16 verifier + an executor whose policy MUST match how the proof was made.
        TD3QueryProofVerifier realVerifier = new TD3QueryProofVerifier();
        ZuitzPassExecutor rexec = new ZuitzPassExecutor();
        rexec.initialize(
            ZuitzPassExecutor.InitParams({
                registrationSMT: REG_SMT,
                verifier: address(realVerifier),
                owner: address(this),
                eventId: j.readUint(".eventId"),
                identityCounterUpperbound: j.readUint(".identityCounterUpperbound"),
                timestampUpperbound: j.readUint(".timestampUpperbound"),
                requireUniqueness: j.readBool(".requireUniqueness"),
                requireNotExpired: j.readBool(".requireNotExpired"),
                birthDateUpperbound: j.readUint(".birthDateUpperbound"),
                currentDateTimeBound: 3650 days
            })
        );

        bytes32 root = j.readBytes32(".registrationRoot");
        uint256 date = j.readUint(".currentDate");
        uint256 nullifier = j.readUint(".nullifier");
        uint256 eventData = j.readUint(".eventData");

        uint256[] memory a = j.readUintArray(".proofA"); // len 2
        uint256[] memory b = j.readUintArray(".proofB"); // len 4 (row-major [b00,b01,b10,b11])
        uint256[] memory c = j.readUintArray(".proofC"); // len 2

        AQueryProofExecutor.ProofPoints memory pts;
        pts.a = [a[0], a[1]];
        pts.b = [[b[0], b[1]], [b[2], b[3]]];
        pts.c = [c[0], c[1]];

        rexec.execute(
            root,
            date,
            abi.encode(ZuitzPassExecutor.QueryPayload({nullifier: nullifier, eventData: eventData})),
            pts
        );

        assertTrue(rexec.usedNullifiers(bytes32(nullifier)), "real proof should be accepted");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    function _payload(uint256 nullifier_, uint256 eventData_) internal pure returns (bytes memory) {
        return abi.encode(ZuitzPassExecutor.QueryPayload({nullifier: nullifier_, eventData: eventData_}));
    }

    function _pts() internal pure returns (AQueryProofExecutor.ProofPoints memory pts) {
        return pts; // mock verifier ignores contents
    }

    function _asciiDate(uint256 yy, uint256 mm, uint256 dd) internal pure returns (uint256 d) {
        d =
            (_d(yy / 10) << 40) |
            (_d(yy % 10) << 32) |
            (_d(mm / 10) << 24) |
            (_d(mm % 10) << 16) |
            (_d(dd / 10) << 8) |
            _d(dd % 10);
    }

    function _d(uint256 n) private pure returns (uint256) {
        return 48 + n;
    }
}
