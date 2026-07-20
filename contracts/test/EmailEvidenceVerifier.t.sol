// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {EmailEvidenceVerifier} from "../src/phase3/EmailEvidenceVerifier.sol";
import {DKIMKeyRegistry} from "../src/phase3/DKIMKeyRegistry.sol";
import {VerifiedHumansTree} from "../src/phase3/VerifiedHumansTree.sol";
import {IHonkVerifier} from "../src/phase3/interfaces/IHonkVerifier.sol";

import {MockEligibilityVerifier} from "./mocks/EligibilityMocks.sol";

contract EmailEvidenceVerifierTest is Test {
    EmailEvidenceVerifier internal evidence;
    DKIMKeyRegistry internal keys;
    VerifiedHumansTree internal credTree;
    MockEligibilityVerifier internal verifier;

    bytes32 internal constant SOURCE = keccak256("luma:evt_cannes2026");
    bytes32 internal constant DOMAIN = keccak256("lu.ma");
    bytes32 internal constant KH0 = bytes32(uint256(0x11));
    bytes32 internal constant KH1 = bytes32(uint256(0x22));
    uint256 internal constant EVENT_ID = 0xE7E27;
    uint256 internal constant EMAIL_NULL = 0xBEEF;
    bytes32 internal constant C = keccak256("credential-C");

    function setUp() public {
        vm.warp(1_900_000_000);
        verifier = new MockEligibilityVerifier();
        keys = new DKIMKeyRegistry(address(this));
        credTree = new VerifiedHumansTree(address(this), 20, 1 hours);
        evidence = new EmailEvidenceVerifier(address(this), IHonkVerifier(address(verifier)), keys);

        credTree.setWriter(address(evidence));
        keys.registerKey(DOMAIN, KH0, KH1);
        evidence.registerSource(SOURCE, DOMAIN, EVENT_ID, credTree);
    }

    function _pub(bytes32 kh0, bytes32 kh1, uint256 eventId, uint256 emailNull, bytes32 c)
        internal
        pure
        returns (bytes32[] memory p)
    {
        p = new bytes32[](5);
        p[0] = kh0;
        p[1] = kh1;
        p[2] = bytes32(eventId);
        p[3] = bytes32(emailNull);
        p[4] = c;
    }

    function _ok() internal pure returns (bytes32[] memory) {
        return _pub(KH0, KH1, EVENT_ID, EMAIL_NULL, C);
    }

    function test_Submit_InsertsCredential() public {
        // Permissionless: a relayer, not the user, submits.
        vm.prank(address(0xB0B));
        evidence.submitEvidence(SOURCE, "", _ok());

        assertTrue(evidence.consumedEmailNullifier(EMAIL_NULL), "email nullifier consumed");
        assertTrue(credTree.getProof(C).existence, "credential inserted (Part A)");
    }

    function test_Submit_SameEmailTwice_Reverts() public {
        evidence.submitEvidence(SOURCE, "", _ok());
        // Same email (same nullifier), even with a different credential commitment.
        bytes32[] memory p = _pub(KH0, KH1, EVENT_ID, EMAIL_NULL, keccak256("other-C"));
        vm.expectRevert(abi.encodeWithSelector(EmailEvidenceVerifier.EmailAlreadyUsed.selector, EMAIL_NULL));
        evidence.submitEvidence(SOURCE, "", p);
    }

    function test_Submit_BadProof_Reverts() public {
        verifier.setResult(false);
        vm.expectRevert(EmailEvidenceVerifier.ProofInvalid.selector);
        evidence.submitEvidence(SOURCE, "", _ok());
    }

    function test_Submit_UnknownKey_Reverts() public {
        bytes32[] memory p = _pub(bytes32(uint256(0x99)), KH1, EVENT_ID, EMAIL_NULL, C);
        vm.expectRevert(
            abi.encodeWithSelector(EmailEvidenceVerifier.UnknownDkimKey.selector, DOMAIN, bytes32(uint256(0x99)), KH1)
        );
        evidence.submitEvidence(SOURCE, "", p);
    }

    function test_Submit_RetiredKey_Reverts() public {
        keys.retireKey(DOMAIN, KH0, KH1, uint64(block.timestamp)); // immediate cutoff
        vm.expectRevert(abi.encodeWithSelector(EmailEvidenceVerifier.UnknownDkimKey.selector, DOMAIN, KH0, KH1));
        evidence.submitEvidence(SOURCE, "", _ok());
    }

    function test_Submit_RetiredKey_ValidUntilDeadline() public {
        keys.retireKey(DOMAIN, KH0, KH1, uint64(block.timestamp + 1 days)); // acceptance window
        evidence.submitEvidence(SOURCE, "", _ok()); // still fine today
    }

    function test_Submit_WrongEvent_Reverts() public {
        // A valid proof over a DIFFERENT event's token cannot satisfy this source (req 5).
        bytes32[] memory p = _pub(KH0, KH1, 0xD0D0, EMAIL_NULL, C);
        vm.expectRevert(abi.encodeWithSelector(EmailEvidenceVerifier.WrongEvent.selector, 0xD0D0, EVENT_ID));
        evidence.submitEvidence(SOURCE, "", p);
    }

    function test_Submit_DisabledSource_Reverts() public {
        evidence.setSourceEnabled(SOURCE, false);
        vm.expectRevert(abi.encodeWithSelector(EmailEvidenceVerifier.SourceNotEnabled.selector, SOURCE));
        evidence.submitEvidence(SOURCE, "", _ok());
    }

    function test_Submit_BadPubLength_Reverts() public {
        bytes32[] memory p = new bytes32[](4);
        vm.expectRevert(abi.encodeWithSelector(EmailEvidenceVerifier.BadPublicInputLength.selector, 4));
        evidence.submitEvidence(SOURCE, "", p);
    }

    function test_KeyRegistry_ReRegisterLiftsRetirement() public {
        keys.retireKey(DOMAIN, KH0, KH1, uint64(block.timestamp));
        assertFalse(keys.isValidKey(DOMAIN, KH0, KH1));
        keys.registerKey(DOMAIN, KH0, KH1);
        assertTrue(keys.isValidKey(DOMAIN, KH0, KH1));
    }

    function test_KeyRegistry_RetireUnregistered_Reverts() public {
        bytes32 id = keys.keyId(bytes32(uint256(0xAA)), bytes32(uint256(0xBB)));
        vm.expectRevert(abi.encodeWithSelector(DKIMKeyRegistry.KeyNotRegistered.selector, DOMAIN, id));
        keys.retireKey(DOMAIN, bytes32(uint256(0xAA)), bytes32(uint256(0xBB)), 0);
    }
}
