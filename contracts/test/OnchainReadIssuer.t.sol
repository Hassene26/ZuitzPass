// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ClaimsRegistry} from "../src/ClaimsRegistry.sol";
import {OnchainReadIssuer} from "../src/issuers/OnchainReadIssuer.sol";
import {IClaimsRegistry} from "../src/interfaces/IClaimsRegistry.sol";

import {MockBalanceToken} from "./mocks/StatementsMocks.sol";

contract OnchainReadIssuerTest is Test {
    ClaimsRegistry internal claims;
    OnchainReadIssuer internal issuer;
    MockBalanceToken internal token;

    bytes32 internal constant HOLDS_NFT = keccak256("HOLDS_ZUITZ_NFT");
    address internal holder = address(0x0117D);
    address internal stranger = address(0xBAD);

    function setUp() public {
        claims = new ClaimsRegistry(address(this));
        issuer = new OnchainReadIssuer(address(this), IClaimsRegistry(address(claims)));
        token = new MockBalanceToken();

        claims.registerClaimType(HOLDS_NFT, "");
        claims.setIssuer(HOLDS_NFT, address(issuer), true);

        // Condition: holds >= 1 of `token`, claim valid 7 days.
        issuer.setCondition(HOLDS_NFT, address(token), 1, 7 days);
    }

    function test_IssueClaim_WhenBalanceMet() public {
        token.setBalance(holder, 1);
        assertTrue(issuer.eligible(HOLDS_NFT, holder));

        issuer.issueClaim(HOLDS_NFT, holder); // permissionless
        bytes32 subject = issuer.subjectOf(holder);
        assertEq(subject, keccak256(abi.encode(string("onchain"), holder)), "wallet-linked subject");
        assertTrue(claims.hasValidClaim(subject, HOLDS_NFT));
    }

    function test_IssueClaim_BelowThreshold_Reverts() public {
        // balance 0 < 1
        vm.expectRevert(
            abi.encodeWithSelector(OnchainReadIssuer.BalanceTooLow.selector, holder, 0, 1)
        );
        issuer.issueClaim(HOLDS_NFT, holder);
        assertFalse(issuer.eligible(HOLDS_NFT, holder));
    }

    function test_IssueClaim_ConditionNotSet_Reverts() public {
        bytes32 unset = keccak256("UNSET");
        vm.expectRevert(
            abi.encodeWithSelector(OnchainReadIssuer.ConditionNotSet.selector, unset)
        );
        issuer.issueClaim(unset, holder);
    }

    function test_Validity_ClaimExpires() public {
        token.setBalance(holder, 5);
        issuer.issueClaim(HOLDS_NFT, holder);
        bytes32 subject = issuer.subjectOf(holder);

        vm.warp(block.timestamp + 7 days); // expiresAt <= now
        assertFalse(claims.hasValidClaim(subject, HOLDS_NFT), "claim expired, re-check needed");
    }

    function test_SetCondition_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        issuer.setCondition(HOLDS_NFT, address(token), 1, 0);
    }

    function test_RemoveCondition_DisablesIssuance() public {
        token.setBalance(holder, 1);
        issuer.removeCondition(HOLDS_NFT);
        assertFalse(issuer.eligible(HOLDS_NFT, holder));
        vm.expectRevert(
            abi.encodeWithSelector(OnchainReadIssuer.ConditionNotSet.selector, HOLDS_NFT)
        );
        issuer.issueClaim(HOLDS_NFT, holder);
    }

    function test_Issue_Unpermissioned_Reverts() public {
        // Registry-side permission removed -> registry rejects the issue.
        claims.setIssuer(HOLDS_NFT, address(issuer), false);
        token.setBalance(holder, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClaimsRegistry.NotAuthorizedIssuer.selector, HOLDS_NFT, address(issuer)
            )
        );
        issuer.issueClaim(HOLDS_NFT, holder);
    }
}
