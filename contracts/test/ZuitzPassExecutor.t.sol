// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ZuitzPassExecutor} from "../src/ZuitzPassExecutor.sol";
import {ZuitzerlandGovernance} from "../src/ZuitzerlandGovernance.sol";
import {AQueryProofExecutor} from "../src/rarimo/sdk/AQueryProofExecutor.sol";
import {PublicSignalsBuilder} from "../src/rarimo/sdk/lib/PublicSignalsBuilder.sol";
import {Date2Time} from "../src/rarimo/utils/Date2Time.sol";

import {MockRegistrationSMT, MockQueryVerifier} from "./mocks/RarimoMocks.sol";

contract ZuitzPassExecutorTest is Test {
    ZuitzPassExecutor internal exec;
    ZuitzerlandGovernance internal gov;
    MockRegistrationSMT internal smt;
    MockQueryVerifier internal verifier;

    uint256 internal constant EVENT_ID = 0x5a55495450415353; // "ZUITPASS"
    uint256 internal constant ID_COUNTER_MAX = 1;
    uint256 internal constant TS_UPPER = 1_800_000_000; // uniqueness registration cutoff
    uint256 internal constant ZERO_DATE = 0x303030303030;

    bytes32 internal constant ROOT = bytes32(uint256(0xC0FFEE));
    uint256 internal currentDate; // yyMMdd ASCII

    // Mirror of ZuitzPassExecutor.AccessGranted for expectEmit.
    event AccessGranted(address indexed caller, bytes32 indexed nullifier, uint256 eventData);

    function setUp() public {
        smt = new MockRegistrationSMT();
        verifier = new MockQueryVerifier(true);

        exec = new ZuitzPassExecutor();
        exec.initialize(
            ZuitzPassExecutor.InitParams({
                registrationSMT: address(smt),
                verifier: address(verifier),
                owner: address(this),
                eventId: EVENT_ID,
                identityCounterUpperbound: ID_COUNTER_MAX,
                timestampUpperbound: TS_UPPER,
                requireUniqueness: true,
                requireNotExpired: true,
                birthDateUpperbound: 0, // age gate off by default
                currentDateTimeBound: 0 // -> defaults to 1 day
            })
        );

        gov = new ZuitzerlandGovernance(address(exec));
        exec.setGovernance(address(gov));

        // Put block.timestamp near a valid ASCII date so withCurrentDate passes.
        currentDate = _asciiDate(30, 1, 1); // 2030-01-01
        vm.warp(Date2Time.timestampFromDate(currentDate) + 12 hours);
    }

    // ----------------------------------------------------------------------
    // Happy path
    // ----------------------------------------------------------------------
    function test_HappyPath_GrantsAccessAndConsumesNullifier() public {
        uint256 nullifier = 111;
        bytes memory payload = _payload(nullifier, uint256(uint160(address(0xBEEF))));

        vm.expectEmit(true, true, false, true, address(exec));
        emit AccessGranted(address(this), bytes32(nullifier), uint256(uint160(address(0xBEEF))));

        exec.execute(ROOT, currentDate, payload, _pts());

        assertTrue(exec.usedNullifiers(bytes32(nullifier)));
    }

    // ----------------------------------------------------------------------
    // The four gates
    // ----------------------------------------------------------------------
    function test_StaleRoot_Reverts() public {
        smt.setAllValid(false); // isRootValid -> false
        vm.expectRevert(
            abi.encodeWithSelector(
                PublicSignalsBuilder.InvalidRegistrationRoot.selector,
                address(smt),
                ROOT
            )
        );
        exec.execute(ROOT, currentDate, _payload(1, 0), _pts());
    }

    function test_BannedNullifier_Reverts() public {
        uint256 nullifier = 222;
        gov.banNullifier(bytes32(nullifier));

        vm.expectRevert(ZuitzPassExecutor.NullifierBanned.selector);
        exec.execute(ROOT, currentDate, _payload(nullifier, 0), _pts());
    }

    function test_UsedNullifier_Reverts() public {
        uint256 nullifier = 333;
        exec.execute(ROOT, currentDate, _payload(nullifier, 0), _pts());

        vm.expectRevert(ZuitzPassExecutor.NullifierAlreadyUsed.selector);
        exec.execute(ROOT, currentDate, _payload(nullifier, 0), _pts());
    }

    function test_InvalidProof_Reverts() public {
        verifier.setResult(false);
        // Base wraps the failure in InvalidCircomProof(pubSignals, zkPoints); match by selector.
        vm.expectRevert();
        exec.execute(ROOT, currentDate, _payload(444, 0), _pts());
    }

    // ----------------------------------------------------------------------
    // Governance access control
    // ----------------------------------------------------------------------
    function test_OnlyGovernanceCanBan() public {
        // The test contract is the owner but NOT the governance contract.
        vm.expectRevert(ZuitzPassExecutor.NotGovernance.selector);
        exec.setNullifierBanned(bytes32(uint256(1)), true);
    }

    function test_UnbanRestoresAccess() public {
        uint256 nullifier = 555;
        gov.banNullifier(bytes32(nullifier));
        gov.unbanNullifier(bytes32(nullifier));
        exec.execute(ROOT, currentDate, _payload(nullifier, 0), _pts());
        assertTrue(exec.usedNullifiers(bytes32(nullifier)));
    }

    // ----------------------------------------------------------------------
    // Public-signal layout & selector composition
    // ----------------------------------------------------------------------
    function test_PublicSignals_Layout() public view {
        uint256 nullifier = 777;
        uint256 eventData = uint256(uint160(address(0xCAFE)));
        bytes32[] memory s = exec.getPublicSignals(ROOT, currentDate, _payload(nullifier, eventData));

        assertEq(s.length, 23, "23 signals");
        assertEq(uint256(s[0]), nullifier, "nullifier @0");
        assertEq(uint256(s[9]), EVENT_ID, "eventId @9");
        assertEq(uint256(s[10]), eventData, "eventData @10");
        assertEq(uint256(s[11]), uint256(ROOT), "idStateRoot @11");
        assertEq(uint256(s[12]), exec.selector(), "selector @12");
        assertEq(uint256(s[13]), currentDate, "currentDate @13");
        // uniqueness (timestamp cutoff + identity counter bounds)
        assertEq(uint256(s[14]), 0, "timestamp lower @14");
        assertEq(uint256(s[15]), TS_UPPER, "timestamp upper @15");
        assertEq(uint256(s[16]), 0, "idCounter lower @16");
        assertEq(uint256(s[17]), ID_COUNTER_MAX, "idCounter upper @17");
        // not-expired (expiration lower = currentDate)
        assertEq(uint256(s[20]), currentDate, "expiration lower @20");
        // age gate off -> birthdate bounds remain ZERO_DATE
        assertEq(uint256(s[18]), ZERO_DATE, "birthdate lower @18");
        assertEq(uint256(s[19]), ZERO_DATE, "birthdate upper @19");
    }

    function test_Selector_TracksPolicy() public {
        // default policy: nullifier + uniqueness (ts-upper + counter-upper) + not-expired
        uint256 base = (1 << 0) | (1 << 9) | (1 << 11) | (1 << 12);
        assertEq(exec.selector(), base, "base selector");

        // enable age gate -> birthdate bits added
        exec.setPolicy(ID_COUNTER_MAX, TS_UPPER, true, true, _asciiDate(12, 1, 1), 0);
        assertEq(exec.selector(), base | (1 << 14) | (1 << 15), "with age");

        // drop uniqueness -> uniqueness bits removed
        exec.setPolicy(ID_COUNTER_MAX, TS_UPPER, false, true, 0, 0);
        assertEq(exec.selector(), (1 << 0) | (1 << 12), "no uniqueness, no age");
    }

    // ----------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------
    function _payload(uint256 nullifier_, uint256 eventData_) internal pure returns (bytes memory) {
        return abi.encode(ZuitzPassExecutor.QueryPayload({nullifier: nullifier_, eventData: eventData_}));
    }

    function _pts() internal pure returns (AQueryProofExecutor.ProofPoints memory pts) {
        // Contents are irrelevant — MockQueryVerifier returns a fixed result.
        return pts;
    }

    /// @dev Build a `yyMMdd` ASCII-encoded date in the low 6 bytes (matches Date2Time).
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
        return 48 + n; // ASCII '0' + n
    }
}
