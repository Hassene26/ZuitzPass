// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ZuitzerlandVerifier} from "../../src/archive/ZuitzerlandVerifier.sol";
import {ZuitzerlandGovernance} from "../../src/ZuitzerlandGovernance.sol";
import {RarimoAdapter} from "../../src/archive/adapters/RarimoAdapter.sol";
import {ZkPassportAdapter} from "../../src/archive/adapters/ZkPassportAdapter.sol";
import {ProofSubmission} from "../../src/archive/interfaces/IZuitzerland.sol";
import {MockEvidenceRegistry, MockNoirVerifier} from "./mocks/Mocks.sol";

contract ZuitzerlandVerifierTest is Test {
    ZuitzerlandVerifier verifier;
    ZuitzerlandGovernance governance;
    RarimoAdapter rarimo;
    ZkPassportAdapter zkPassport;
    MockEvidenceRegistry registry; // ONE shared ERC-7812 singleton
    MockNoirVerifier noir;

    address user = address(0xBEEF);
    address admin = address(this);

    // Provider registrar addresses (the `source` in getIsolatedKey).
    address constant RARIMO_REGISTRAR = address(0x4A41);
    address constant ZK_REGISTRAR = address(0x21C0);

    bytes32 constant ROOT = bytes32(uint256(0xA11CE));
    bytes32 constant NULLIFIER = bytes32(uint256(0x1111));
    bytes32 constant SESSION = bytes32(uint256(0x5E5510));

    // Per-provider freshness policy.
    uint256 constant RARIMO_WINDOW = 7 days; // Rarimo roots: valid 1 week
    uint256 constant ZK_WINDOW = 180 days; // zkPassport roots: valid ~6 months

    function setUp() public {
        // Warp to a realistic timestamp so `block.timestamp - ts` never underflows.
        vm.warp(365 days);

        registry = new MockEvidenceRegistry();
        noir = new MockNoirVerifier();

        verifier = new ZuitzerlandVerifier(address(registry), address(noir));

        rarimo = new RarimoAdapter(RARIMO_REGISTRAR, RARIMO_WINDOW);
        zkPassport = new ZkPassportAdapter(ZK_REGISTRAR, ZK_WINDOW);

        verifier.setAdapter(address(rarimo), true);
        verifier.setAdapter(address(zkPassport), true);

        governance = new ZuitzerlandGovernance(address(verifier));
        verifier.setGovernance(address(governance));

        // Make ROOT recent in the shared registry by default.
        registry.setRootTimestamp(ROOT, block.timestamp);
    }

    function _sub() internal pure returns (ProofSubmission memory) {
        return ProofSubmission({
            proof: hex"00",
            root: ROOT,
            nullifier: NULLIFIER,
            sessionBinding: SESSION,
            provider: address(0) // filled by caller
        });
    }

    function _rarimoSub() internal view returns (ProofSubmission memory s) {
        s = _sub();
        s.provider = address(rarimo);
    }

    // 1. Happy path
    function test_HappyPath() public {
        ProofSubmission memory s = _rarimoSub();
        vm.prank(user);
        verifier.verify(s);
        assertTrue(verifier.usedNullifiers(NULLIFIER));
    }

    // 2. Stale root
    function test_StaleRoot_Reverts() public {
        // Registered 8 days ago -> outside Rarimo's 7-day window.
        registry.setRootTimestamp(ROOT, block.timestamp - 8 days);
        ProofSubmission memory s = _rarimoSub();
        vm.prank(user);
        vm.expectRevert(ZuitzerlandVerifier.RootExpired.selector);
        verifier.verify(s);
    }

    // 2b. Per-provider windows: the SAME root age is rejected by Rarimo
    //     (7-day window) but accepted by zkPassport (6-month window).
    function test_PerProviderWindows() public {
        // A root registered 30 days ago.
        uint256 ts = block.timestamp - 30 days;
        registry.setRootTimestamp(ROOT, ts); // one shared root for both providers

        // Rarimo: 30 days > 7 days -> expired.
        ProofSubmission memory rSub = _rarimoSub();
        vm.prank(user);
        vm.expectRevert(ZuitzerlandVerifier.RootExpired.selector);
        verifier.verify(rSub);

        // zkPassport: 30 days < 180 days -> still valid.
        ProofSubmission memory zSub = _sub();
        zSub.provider = address(zkPassport);
        vm.prank(user);
        verifier.verify(zSub);
        assertTrue(verifier.usedNullifiers(NULLIFIER));
    }

    // 3. Reused nullifier
    function test_ReusedNullifier_Reverts() public {
        ProofSubmission memory s = _rarimoSub();
        vm.prank(user);
        verifier.verify(s);

        vm.prank(user);
        vm.expectRevert(ZuitzerlandVerifier.NullifierAlreadyUsed.selector);
        verifier.verify(s);
    }

    // 4. Banned nullifier
    function test_BannedNullifier_Reverts() public {
        governance.banNullifier(NULLIFIER);
        ProofSubmission memory s = _rarimoSub();
        vm.prank(user);
        vm.expectRevert(ZuitzerlandVerifier.NullifierBanned.selector);
        verifier.verify(s);
    }

    // 5. Collusion attack: different session bindings across two proofs
    function test_SessionBindingMismatch_Reverts() public {
        // ZkPassport root must also be recent.
        registry.setRootTimestamp(ROOT, block.timestamp);

        ProofSubmission[] memory proofs = new ProofSubmission[](2);
        proofs[0] = _rarimoSub();

        ProofSubmission memory s2 = _sub();
        s2.provider = address(zkPassport);
        s2.nullifier = bytes32(uint256(0x2222));
        s2.sessionBinding = bytes32(uint256(0xDEAD)); // different session
        proofs[1] = s2;

        vm.prank(user);
        vm.expectRevert(ZuitzerlandVerifier.SessionBindingMismatch.selector);
        verifier.verifyMultiProof(proofs);
    }

    // Bonus: multi-proof happy path with matching session bindings
    function test_MultiProof_HappyPath() public {
        registry.setRootTimestamp(ROOT, block.timestamp);

        ProofSubmission[] memory proofs = new ProofSubmission[](2);
        proofs[0] = _rarimoSub();

        ProofSubmission memory s2 = _sub();
        s2.provider = address(zkPassport);
        s2.nullifier = bytes32(uint256(0x2222));
        proofs[1] = s2;

        vm.prank(user);
        verifier.verifyMultiProof(proofs);
        assertTrue(verifier.usedNullifiers(NULLIFIER));
        assertTrue(verifier.usedNullifiers(bytes32(uint256(0x2222))));
    }

    // 6. Ban flow: admin bans, subsequent submission reverts
    function test_BanFlow() public {
        // Works before ban.
        ProofSubmission memory s = _rarimoSub();
        s.nullifier = bytes32(uint256(0x9999));
        registry.setRootTimestamp(s.root, block.timestamp);

        // Now ban a different nullifier and confirm it is rejected.
        governance.banNullifier(NULLIFIER);

        ProofSubmission memory banned = _rarimoSub();
        vm.prank(user);
        vm.expectRevert(ZuitzerlandVerifier.NullifierBanned.selector);
        verifier.verify(banned);

        // Unban restores access.
        governance.unbanNullifier(NULLIFIER);
        vm.prank(user);
        verifier.verify(banned);
        assertTrue(verifier.usedNullifiers(NULLIFIER));
    }

    // Extra: invalid proof path
    function test_InvalidProof_Reverts() public {
        noir.setVerdict(false);
        ProofSubmission memory s = _rarimoSub();
        vm.prank(user);
        vm.expectRevert(ZuitzerlandVerifier.InvalidProof.selector);
        verifier.verify(s);
    }

    // Extra: only governance can flip ban flag directly
    function test_OnlyGovernance_CanBan() public {
        vm.prank(user);
        vm.expectRevert(ZuitzerlandVerifier.NotGovernance.selector);
        verifier.setNullifierBanned(NULLIFIER, true);
    }

    // Extra: the chosen adapter's registrar is forced into the proof's public
    // inputs (index 3). A proof scoped to a different registrar fails verification,
    // so a user cannot borrow zkPassport's longer window with a Rarimo proof.
    function test_RegistrarBoundIntoPublicInputs() public {
        // This stand-in only returns true if public inputs are
        // [_, _, _, ZK_REGISTRAR] with length 4 — i.e. the verifier appended the
        // zkPassport adapter's registrar. If it didn't, verify() reverts InvalidProof.
        InspectingVerifier inspector =
            new InspectingVerifier(bytes32(uint256(uint160(ZK_REGISTRAR))));
        verifier.setNoirVerifier(address(inspector));

        ProofSubmission memory s = _sub();
        s.provider = address(zkPassport);
        vm.prank(user);
        verifier.verify(s); // succeeds only because index 3 == ZK_REGISTRAR
        assertTrue(verifier.usedNullifiers(NULLIFIER));
    }

    // Negative: a proof presented through the WRONG adapter (Rarimo) fails, because
    // the verifier appends Rarimo's registrar but the proof expects zkPassport's.
    function test_WrongRegistrar_FailsVerification() public {
        InspectingVerifier inspector =
            new InspectingVerifier(bytes32(uint256(uint160(ZK_REGISTRAR))));
        verifier.setNoirVerifier(address(inspector));

        ProofSubmission memory s = _rarimoSub(); // wrong provider for this proof
        vm.prank(user);
        vm.expectRevert(ZuitzerlandVerifier.InvalidProof.selector);
        verifier.verify(s);
    }
}

/// @dev Noir-verifier stand-in: returns true only if the public inputs end with the
///      expected registrar and have length 4. `view`, so it is STATICCALL-safe.
contract InspectingVerifier {
    bytes32 public immutable expectedRegistrar;

    constructor(bytes32 _expectedRegistrar) {
        expectedRegistrar = _expectedRegistrar;
    }

    function verifyProof(bytes calldata, bytes32[] calldata publicInputs)
        external
        view
        returns (bool)
    {
        return publicInputs.length == 4 && publicInputs[3] == expectedRegistrar;
    }
}
