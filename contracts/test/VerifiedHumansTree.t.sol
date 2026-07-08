// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerifiedHumansTree} from "../src/phase3/VerifiedHumansTree.sol";
import {RootedSMTRegistry} from "../src/phase3/RootedSMTRegistry.sol";

contract VerifiedHumansTreeTest is Test {
    VerifiedHumansTree internal vht;
    address internal inserter = address(0xC0FFEE);

    function setUp() public {
        vht = new VerifiedHumansTree(address(this), 20, 1 hours);
        vht.setWriter(inserter);
    }

    function test_InsertCredential_ProducesFreshValidRoot() public {
        vm.prank(inserter);
        vht.insertCredential(keccak256("C1"));
        bytes32 root = vht.getRoot();
        assertTrue(root != bytes32(0));
        assertTrue(vht.isRootValid(root));
    }

    function test_OnlyWriter_CanInsert() public {
        vm.expectRevert(RootedSMTRegistry.NotWriter.selector);
        vht.insertCredential(keccak256("C1"));
    }

    function test_Root_ExpiresOutsideWindow() public {
        vm.startPrank(inserter);
        vht.insertCredential(keccak256("C1"));
        vm.stopPrank();
        bytes32 root = vht.getRoot();
        assertTrue(vht.isRootValid(root));
        vm.warp(block.timestamp + 1 hours + 1);
        assertFalse(vht.isRootValid(root));
    }
}
