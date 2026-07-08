// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ClaimsRegistry} from "../src/ClaimsRegistry.sol";
import {StatementRegistry} from "../src/StatementRegistry.sol";
import {IClaimsRegistry} from "../src/interfaces/IClaimsRegistry.sol";
import {Statement} from "../src/interfaces/IStatementRegistry.sol";

contract StatementRegistryTest is Test {
    ClaimsRegistry internal claims;
    StatementRegistry internal statements;

    bytes32 internal constant HUMAN_RARIMO = keccak256("UNIQUE_HUMAN_RARIMO");
    bytes32 internal constant HUMAN_WORLDID = keccak256("UNIQUE_HUMAN_WORLDID");
    bytes32 internal constant ATTENDEE = keccak256("ZUITZ_MAY25_ATTENDEE");
    bytes32 internal constant OVER_18 = keccak256("OVER_18");

    bytes32 internal constant S_FULL = keccak256("ALPS_RESIDENCY_2026");
    bytes32 internal constant S_ATTEND_ONLY = keccak256("ATTEND_ONLY");

    bytes32 internal constant ALICE = keccak256("alice");

    address internal poolApp = address(0xA1);
    address internal forumApp = address(0xF0);

    function setUp() public {
        claims = new ClaimsRegistry(address(this));
        statements = new StatementRegistry(address(this), IClaimsRegistry(address(claims)));

        bytes32[4] memory types = [HUMAN_RARIMO, HUMAN_WORLDID, ATTENDEE, OVER_18];
        for (uint256 i = 0; i < types.length; ++i) {
            claims.registerClaimType(types[i], "");
            claims.setIssuer(types[i], address(this), true); // this test is the issuer
        }

        // S_FULL: (ATTENDEE AND OVER_18) AND (RARIMO OR WORLDID), consumable.
        statements.registerStatement(S_FULL, _statement(_two(ATTENDEE, OVER_18), _two(HUMAN_RARIMO, HUMAN_WORLDID), true));
        // S_ATTEND_ONLY: allOf [ATTENDEE], empty anyOf, NOT consumable.
        statements.registerStatement(S_ATTEND_ONLY, _statement(_one(ATTENDEE), new bytes32[](0), false));
    }

    // ----------------------------------------------------------------------
    // check — allOf / anyOf semantics
    // ----------------------------------------------------------------------
    function test_Check_AllConditionsMet() public {
        _giveAliceBaseClaims();
        claims.issue(ALICE, HUMAN_RARIMO, 0);
        assertTrue(statements.check(ALICE, S_FULL));
    }

    function test_Check_MissingAllOf_Fails() public {
        // Has personhood + over18 but NOT attendance.
        claims.issue(ALICE, OVER_18, 0);
        claims.issue(ALICE, HUMAN_RARIMO, 0);
        assertFalse(statements.check(ALICE, S_FULL), "missing allOf ATTENDEE");
    }

    function test_Check_AnyOf_EitherProviderSatisfies() public {
        _giveAliceBaseClaims();
        // Only WORLDID (second anyOf entry) present -> still eligible.
        claims.issue(ALICE, HUMAN_WORLDID, 0);
        assertTrue(statements.check(ALICE, S_FULL), "worldid satisfies anyOf");

        // Replace with only RARIMO (first anyOf entry, short-circuit) -> still eligible.
        claims.revoke(ALICE, HUMAN_WORLDID);
        claims.issue(ALICE, HUMAN_RARIMO, 0);
        assertTrue(statements.check(ALICE, S_FULL), "rarimo satisfies anyOf");
    }

    function test_Check_AnyOf_NoneMet_Fails() public {
        _giveAliceBaseClaims(); // attendance + over18, but no personhood provider
        assertFalse(statements.check(ALICE, S_FULL), "anyOf unsatisfied");
    }

    function test_Check_EmptyAnyOf_Skipped() public {
        claims.issue(ALICE, ATTENDEE, 0);
        // S_ATTEND_ONLY has empty anyOf -> only allOf must hold.
        assertTrue(statements.check(ALICE, S_ATTEND_ONLY), "empty anyOf skipped");
    }

    function test_Check_UnregisteredStatement_Reverts() public {
        bytes32 nope = keccak256("NOPE");
        vm.expectRevert(
            abi.encodeWithSelector(StatementRegistry.StatementNotRegistered.selector, nope)
        );
        statements.check(ALICE, nope);
    }

    // ----------------------------------------------------------------------
    // consume — per-app, per-context one-time semantics
    // ----------------------------------------------------------------------
    function test_Consume_HappyPath() public {
        _makeAliceFullyEligible();

        vm.prank(poolApp);
        statements.consume(ALICE, S_FULL, 202608);
        assertTrue(statements.isConsumed(S_FULL, poolApp, 202608, ALICE));
    }

    function test_Consume_SecondReverts() public {
        _makeAliceFullyEligible();
        vm.startPrank(poolApp);
        statements.consume(ALICE, S_FULL, 202608);
        vm.expectRevert(
            abi.encodeWithSelector(
                StatementRegistry.AlreadyConsumed.selector, S_FULL, poolApp, 202608, ALICE
            )
        );
        statements.consume(ALICE, S_FULL, 202608);
        vm.stopPrank();
    }

    function test_Consume_DifferentContext_Independent() public {
        _makeAliceFullyEligible();
        vm.startPrank(poolApp);
        statements.consume(ALICE, S_FULL, 202608); // August
        statements.consume(ALICE, S_FULL, 202609); // September — new epoch, allowed
        vm.stopPrank();
        assertTrue(statements.isConsumed(S_FULL, poolApp, 202609, ALICE));
    }

    function test_Consume_DifferentApp_Independent() public {
        _makeAliceFullyEligible();
        vm.prank(poolApp);
        statements.consume(ALICE, S_FULL, 202608);

        // The forum checking the same statement cannot have its eligibility burned by the pool.
        assertFalse(statements.isConsumed(S_FULL, forumApp, 202608, ALICE));
        vm.prank(forumApp);
        statements.consume(ALICE, S_FULL, 202608);
        assertTrue(statements.isConsumed(S_FULL, forumApp, 202608, ALICE));
    }

    function test_Consume_NotEligible_Reverts() public {
        // Alice lacks all claims.
        vm.prank(poolApp);
        vm.expectRevert(
            abi.encodeWithSelector(StatementRegistry.NotEligible.selector, ALICE, S_FULL)
        );
        statements.consume(ALICE, S_FULL, 202608);
    }

    function test_Consume_NotConsumable_Reverts() public {
        claims.issue(ALICE, ATTENDEE, 0);
        vm.prank(poolApp);
        vm.expectRevert(
            abi.encodeWithSelector(StatementRegistry.NotConsumable.selector, S_ATTEND_ONLY)
        );
        statements.consume(ALICE, S_ATTEND_ONLY, 1);
    }

    // ----------------------------------------------------------------------
    // registration permissioning
    // ----------------------------------------------------------------------
    function test_RegisterStatement_OnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        statements.registerStatement(keccak256("X"), _statement(_one(ATTENDEE), new bytes32[](0), false));
    }

    function test_RegisterStatement_DuplicateReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(StatementRegistry.StatementAlreadyRegistered.selector, S_FULL)
        );
        statements.registerStatement(S_FULL, _statement(_one(ATTENDEE), new bytes32[](0), true));
    }

    // ----------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------
    function _giveAliceBaseClaims() internal {
        claims.issue(ALICE, ATTENDEE, 0);
        claims.issue(ALICE, OVER_18, 0);
    }

    function _makeAliceFullyEligible() internal {
        _giveAliceBaseClaims();
        claims.issue(ALICE, HUMAN_RARIMO, 0);
    }

    function _statement(bytes32[] memory allOf_, bytes32[] memory anyOf_, bool consumable_)
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

    function _two(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
