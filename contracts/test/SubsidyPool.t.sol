// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ClaimsRegistry} from "../src/ClaimsRegistry.sol";
import {StatementRegistry} from "../src/StatementRegistry.sol";
import {SubsidyPool} from "../src/demo/SubsidyPool.sol";
import {IClaimsRegistry} from "../src/interfaces/IClaimsRegistry.sol";
import {IStatementRegistry, Statement} from "../src/interfaces/IStatementRegistry.sol";

/// @notice Demonstrates the §8 consumer flow end to end: a funded pool pays a subsidy to an
///         eligible subject once per epoch, gated purely on `check`/`consume`.
contract SubsidyPoolTest is Test {
    ClaimsRegistry internal claims;
    StatementRegistry internal statements;
    SubsidyPool internal pool;

    bytes32 internal constant HUMAN_RARIMO = keccak256("UNIQUE_HUMAN_RARIMO");
    bytes32 internal constant HUMAN_WORLDID = keccak256("UNIQUE_HUMAN_WORLDID");
    bytes32 internal constant ATTENDEE = keccak256("ZUITZ_MAY25_ATTENDEE");
    bytes32 internal constant OVER_18 = keccak256("OVER_18");
    bytes32 internal constant ALPS = keccak256("ALPS_RESIDENCY_2026");

    bytes32 internal constant ALICE = keccak256("alice-subject");
    uint256 internal constant PAYOUT = 1 ether;
    uint256 internal constant EPOCH = 30 days;

    address internal alice = address(0xA11CE);

    function setUp() public {
        claims = new ClaimsRegistry(address(this));
        statements = new StatementRegistry(address(this), IClaimsRegistry(address(claims)));

        bytes32[4] memory types = [HUMAN_RARIMO, HUMAN_WORLDID, ATTENDEE, OVER_18];
        for (uint256 i = 0; i < types.length; ++i) {
            claims.registerClaimType(types[i], "");
            claims.setIssuer(types[i], address(this), true);
        }

        statements.registerStatement(
            ALPS,
            Statement({
                allOf: _two(ATTENDEE, OVER_18),
                anyOf: _two(HUMAN_RARIMO, HUMAN_WORLDID),
                consumable: true,
                metadataURI: ""
            })
        );

        pool = new SubsidyPool(address(this), IStatementRegistry(address(statements)), ALPS, PAYOUT, EPOCH);
        vm.deal(address(pool), 10 ether); // organizers fund the pool

        // Warp off epoch 0 so timestamps are realistic.
        vm.warp(1_900_000_000);
    }

    function _makeAliceEligible() internal {
        claims.issue(ALICE, ATTENDEE, 0);
        claims.issue(ALICE, OVER_18, 0);
        claims.issue(ALICE, HUMAN_RARIMO, 0);
    }

    // ----------------------------------------------------------------------
    // Happy path
    // ----------------------------------------------------------------------
    function test_Claim_PaysOutAndConsumes() public {
        _makeAliceEligible();
        assertTrue(pool.eligible(ALICE));

        uint256 before = alice.balance;
        vm.prank(alice);
        pool.claim(ALICE);

        assertEq(alice.balance, before + PAYOUT, "alice paid");
        assertEq(address(pool).balance, 10 ether - PAYOUT, "pool debited");
        assertTrue(pool.hasClaimedThisEpoch(ALICE));
    }

    function test_Claim_SecondSameEpoch_Reverts() public {
        _makeAliceEligible();
        vm.startPrank(alice);
        pool.claim(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                StatementRegistry.AlreadyConsumed.selector, ALPS, address(pool), pool.currentEpoch(), ALICE
            )
        );
        pool.claim(ALICE);
        vm.stopPrank();
    }

    function test_Claim_NextEpoch_Allowed() public {
        _makeAliceEligible();
        vm.prank(alice);
        pool.claim(ALICE);

        vm.warp(block.timestamp + EPOCH); // roll to the next epoch
        assertFalse(pool.hasClaimedThisEpoch(ALICE), "fresh epoch");
        vm.prank(alice);
        pool.claim(ALICE);
        assertEq(alice.balance, 2 * PAYOUT, "claimed twice across epochs");
    }

    // ----------------------------------------------------------------------
    // Gating
    // ----------------------------------------------------------------------
    function test_Claim_Ineligible_Reverts() public {
        // Alice has no claims.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StatementRegistry.NotEligible.selector, ALICE, ALPS)
        );
        pool.claim(ALICE);
    }

    function test_Claim_InsufficientBalance_Reverts() public {
        _makeAliceEligible();
        // Drain the pool first.
        pool.withdraw(payable(address(this)), address(pool).balance);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SubsidyPool.InsufficientPoolBalance.selector, 0, PAYOUT)
        );
        pool.claim(ALICE);
    }

    // ----------------------------------------------------------------------
    // Funding / admin
    // ----------------------------------------------------------------------
    function test_Fund_And_Withdraw() public {
        pool.fund{value: 1 ether}();
        assertEq(address(pool).balance, 11 ether);

        uint256 before = address(this).balance;
        pool.withdraw(payable(address(this)), 5 ether);
        assertEq(address(this).balance, before + 5 ether);
    }

    function test_Withdraw_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        pool.withdraw(payable(alice), 1 ether);
    }

    // ----------------------------------------------------------------------
    // Reentrancy — consume commits before payout, so no double-spend
    // ----------------------------------------------------------------------
    function test_Reentrancy_NoDoubleSpend() public {
        ReentrantClaimer attacker = new ReentrantClaimer(pool, ALICE);
        // Make the attacker's subject eligible.
        claims.issue(ALICE, ATTENDEE, 0);
        claims.issue(ALICE, OVER_18, 0);
        claims.issue(ALICE, HUMAN_RARIMO, 0);

        uint256 poolBefore = address(pool).balance;
        // The reentrant call reverts AlreadyConsumed inside receive() -> outer payout fails.
        vm.expectRevert(SubsidyPool.PayoutFailed.selector);
        attacker.go();

        // Whole tx reverted: no funds moved, subject not consumed.
        assertEq(address(pool).balance, poolBefore, "pool untouched");
        assertFalse(pool.hasClaimedThisEpoch(ALICE), "not consumed");
    }

    // Accept withdrawals / payouts.
    receive() external payable {}

    function _two(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](2);
        arr[0] = a;
        arr[1] = b;
    }
}

/// @notice Reenters `claim` on payout to attempt a double-spend.
contract ReentrantClaimer {
    SubsidyPool internal immutable pool;
    bytes32 internal immutable subject;
    bool internal reentered;

    constructor(SubsidyPool pool_, bytes32 subject_) {
        pool = pool_;
        subject = subject_;
    }

    function go() external {
        pool.claim(subject);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            pool.claim(subject); // reverts AlreadyConsumed
        }
    }
}
