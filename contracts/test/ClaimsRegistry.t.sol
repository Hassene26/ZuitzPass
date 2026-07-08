// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ClaimsRegistry} from "../src/ClaimsRegistry.sol";
import {Claim} from "../src/interfaces/IClaimsRegistry.sol";
import {ZuitzerlandGovernance} from "../src/ZuitzerlandGovernance.sol";

contract ClaimsRegistryTest is Test {
    ClaimsRegistry internal registry;
    ZuitzerlandGovernance internal gov;

    bytes32 internal constant HUMAN = keccak256("UNIQUE_HUMAN_RARIMO");
    bytes32 internal constant OVER_18 = keccak256("OVER_18");
    bytes32 internal constant SUBJECT = keccak256("subject-A");

    address internal issuer = address(0x15);
    address internal stranger = address(0xBAD);

    function setUp() public {
        registry = new ClaimsRegistry(address(this)); // owner = this (stands in for multisig)

        // Ban key lives with the ZuitzerlandGovernance wrapper (drives it unchanged).
        gov = new ZuitzerlandGovernance(address(registry));
        registry.setGovernance(address(gov));

        registry.registerClaimType(HUMAN, "ipfs://human");
        registry.registerClaimType(OVER_18, "ipfs://over18");
        registry.setIssuer(HUMAN, issuer, true);
        registry.setIssuer(OVER_18, issuer, true);
    }

    // ----------------------------------------------------------------------
    // Claim-type registration & issuer permissioning
    // ----------------------------------------------------------------------
    function test_RegisterClaimType_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.registerClaimType(keccak256("X"), "");
    }

    function test_RegisterClaimType_DuplicateReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ClaimsRegistry.ClaimTypeAlreadyRegistered.selector, HUMAN)
        );
        registry.registerClaimType(HUMAN, "");
    }

    function test_SetIssuer_RequiresRegisteredType() public {
        bytes32 unreg = keccak256("UNREGISTERED");
        vm.expectRevert(
            abi.encodeWithSelector(ClaimsRegistry.ClaimTypeNotRegistered.selector, unreg)
        );
        registry.setIssuer(unreg, issuer, true);
    }

    function test_Issue_RequiresAllowedIssuer() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(ClaimsRegistry.NotAuthorizedIssuer.selector, HUMAN, stranger)
        );
        registry.issue(SUBJECT, HUMAN, 0);
    }

    // ----------------------------------------------------------------------
    // Issue / read / expiry
    // ----------------------------------------------------------------------
    function test_Issue_HappyPath() public {
        vm.prank(issuer);
        registry.issue(SUBJECT, HUMAN, uint64(block.timestamp + 100));

        assertTrue(registry.hasValidClaim(SUBJECT, HUMAN));
        Claim memory c = registry.getClaim(SUBJECT, HUMAN);
        assertEq(c.issuer, issuer, "issuer recorded");
        assertEq(c.issuedAt, uint64(block.timestamp), "issuedAt");
        assertEq(c.expiresAt, uint64(block.timestamp + 100), "expiresAt");
    }

    function test_NeverExpires_WhenZero() public {
        vm.prank(issuer);
        registry.issue(SUBJECT, HUMAN, 0);
        vm.warp(block.timestamp + 3650 days);
        assertTrue(registry.hasValidClaim(SUBJECT, HUMAN), "0 expiry = never expires");
    }

    function test_Expiry_InvalidatesClaim() public {
        uint64 exp = uint64(block.timestamp + 100);
        vm.prank(issuer);
        registry.issue(SUBJECT, HUMAN, exp);

        vm.warp(exp - 1);
        assertTrue(registry.hasValidClaim(SUBJECT, HUMAN), "valid just before expiry");
        vm.warp(exp); // expiresAt <= now => expired
        assertFalse(registry.hasValidClaim(SUBJECT, HUMAN), "expired at boundary");
    }

    function test_Reissue_Overwrites() public {
        vm.startPrank(issuer);
        registry.issue(SUBJECT, HUMAN, uint64(block.timestamp + 1));
        registry.issue(SUBJECT, HUMAN, uint64(block.timestamp + 1000));
        vm.stopPrank();

        vm.warp(block.timestamp + 500);
        assertTrue(registry.hasValidClaim(SUBJECT, HUMAN), "refreshed expiry applies");
    }

    function test_UnknownClaim_IsInvalid() public view {
        assertFalse(registry.hasValidClaim(SUBJECT, HUMAN));
    }

    // ----------------------------------------------------------------------
    // Revoke
    // ----------------------------------------------------------------------
    function test_Revoke_ByIssuer() public {
        vm.startPrank(issuer);
        registry.issue(SUBJECT, HUMAN, 0);
        registry.revoke(SUBJECT, HUMAN);
        vm.stopPrank();
        assertFalse(registry.hasValidClaim(SUBJECT, HUMAN));
    }

    function test_Revoke_ByOwnerGovernance() public {
        vm.prank(issuer);
        registry.issue(SUBJECT, HUMAN, 0);
        registry.revoke(SUBJECT, HUMAN); // owner path
        assertFalse(registry.hasValidClaim(SUBJECT, HUMAN));
    }

    function test_Revoke_Unauthorized_Reverts() public {
        vm.prank(issuer);
        registry.issue(SUBJECT, HUMAN, 0);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(ClaimsRegistry.NotAuthorizedIssuer.selector, HUMAN, stranger)
        );
        registry.revoke(SUBJECT, HUMAN);
    }

    function test_Revoke_NotFound_Reverts() public {
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(ClaimsRegistry.ClaimNotFound.selector, SUBJECT, HUMAN)
        );
        registry.revoke(SUBJECT, HUMAN);
    }

    // ----------------------------------------------------------------------
    // Ban — layer-wide, kills ALL of a subject's claims at once
    // ----------------------------------------------------------------------
    function test_Ban_KillsAllClaims_ThenUnbanRestores() public {
        vm.startPrank(issuer);
        registry.issue(SUBJECT, HUMAN, 0);
        registry.issue(SUBJECT, OVER_18, 0);
        vm.stopPrank();

        assertTrue(registry.hasValidClaim(SUBJECT, HUMAN));
        assertTrue(registry.hasValidClaim(SUBJECT, OVER_18));

        gov.banNullifier(SUBJECT);
        assertFalse(registry.hasValidClaim(SUBJECT, HUMAN), "ban kills HUMAN");
        assertFalse(registry.hasValidClaim(SUBJECT, OVER_18), "ban kills OVER_18");

        gov.unbanNullifier(SUBJECT);
        assertTrue(registry.hasValidClaim(SUBJECT, HUMAN), "unban restores HUMAN");
        assertTrue(registry.hasValidClaim(SUBJECT, OVER_18), "unban restores OVER_18");
    }

    function test_Ban_OnlyGovernance() public {
        // owner is NOT governance — the wrapper holds the ban key.
        vm.expectRevert(ClaimsRegistry.NotGovernance.selector);
        registry.setNullifierBanned(SUBJECT, true);
    }
}
