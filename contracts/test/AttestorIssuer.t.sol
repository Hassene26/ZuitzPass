// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ClaimsRegistry} from "../src/ClaimsRegistry.sol";
import {AttestorIssuer} from "../src/issuers/AttestorIssuer.sol";
import {IClaimsRegistry} from "../src/interfaces/IClaimsRegistry.sol";

contract AttestorIssuerTest is Test {
    ClaimsRegistry internal claims;
    AttestorIssuer internal attestor;

    bytes32 internal constant ATTENDEE = keccak256("ZUITZ_MAY25_ATTENDEE");
    bytes32 internal constant OTHER = keccak256("SOME_OTHER_TYPE");
    bytes32 internal constant SUBJECT = keccak256("alice");

    address internal signer = address(0x51);
    address internal stranger = address(0xBAD);

    function setUp() public {
        claims = new ClaimsRegistry(address(this));
        attestor = new AttestorIssuer(address(this), IClaimsRegistry(address(claims)));

        claims.registerClaimType(ATTENDEE, "");
        claims.registerClaimType(OTHER, "");
        claims.setIssuer(ATTENDEE, address(attestor), true); // attestor may issue ATTENDEE only

        attestor.setSigner(signer, true);
    }

    function test_Attest_HappyPath() public {
        vm.prank(signer);
        attestor.attest(SUBJECT, ATTENDEE);

        assertTrue(claims.hasValidClaim(SUBJECT, ATTENDEE));
        // Attested claims never expire.
        vm.warp(block.timestamp + 3650 days);
        assertTrue(claims.hasValidClaim(SUBJECT, ATTENDEE), "expiry 0");
    }

    function test_Attest_OnlySigner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AttestorIssuer.NotSigner.selector, stranger));
        attestor.attest(SUBJECT, ATTENDEE);
    }

    function test_SetSigner_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        attestor.setSigner(stranger, true);
    }

    function test_RemoveSigner_RevokesAbility() public {
        attestor.setSigner(signer, false);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(AttestorIssuer.NotSigner.selector, signer));
        attestor.attest(SUBJECT, ATTENDEE);
    }

    function test_Attest_UnpermissionedType_Reverts() public {
        // Attestor is not an allowed issuer of OTHER -> the registry rejects the issue.
        vm.prank(signer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimsRegistry.NotAuthorizedIssuer.selector, OTHER, address(attestor)
            )
        );
        attestor.attest(SUBJECT, OTHER);
    }
}
