// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ClaimsSMTRegistry} from "../src/phase3/ClaimsSMTRegistry.sol";

contract ClaimsSMTRegistryTest is Test {
    ClaimsSMTRegistry internal reg;
    address internal redeemer;

    function setUp() public {
        redeemer = address(0xBEEF);
        reg = new ClaimsSMTRegistry(address(this), 20, 1 hours);
        reg.setRedeemer(redeemer);
    }

    function _leaf(uint256 k, uint256 v) internal pure returns (bytes32, bytes32) {
        return (bytes32(k), bytes32(v));
    }

    function test_AddLeaf_ProducesFreshValidRoot() public {
        (bytes32 k, bytes32 v) = _leaf(0xA, 0x1);
        vm.prank(redeemer);
        reg.addClaimLeaf(k, v);

        bytes32 root = reg.getRoot();
        assertTrue(root != bytes32(0), "root set");
        assertTrue(reg.isRootValid(root), "current root valid");
    }

    function test_OnlyRedeemer_CanWrite() public {
        vm.expectRevert(ClaimsSMTRegistry.NotRedeemer.selector);
        reg.addClaimLeaf(bytes32(uint256(1)), bytes32(uint256(1)));
    }

    function test_RootHistory_OldRootValidWithinWindow_ThenExpires() public {
        vm.startPrank(redeemer);
        reg.addClaimLeaf(bytes32(uint256(0xA)), bytes32(uint256(1)));
        bytes32 rootA = reg.getRoot();
        reg.addClaimLeaf(bytes32(uint256(0xB)), bytes32(uint256(2)));
        bytes32 rootB = reg.getRoot();
        vm.stopPrank();

        assertTrue(rootA != rootB, "root advanced");
        // Old root still valid inside the window.
        assertTrue(reg.isRootValid(rootA), "old root valid in window");
        assertTrue(reg.isRootValid(rootB), "new root valid");

        // Past the window, the old root is stale.
        vm.warp(block.timestamp + 1 hours + 1);
        assertFalse(reg.isRootValid(rootA), "old root expired");
    }

    function test_UnknownRoot_Invalid() public view {
        assertFalse(reg.isRootValid(bytes32(uint256(0xDEAD))));
    }

    function test_UpdateLeaf_AdvancesRoot() public {
        vm.startPrank(redeemer);
        reg.addClaimLeaf(bytes32(uint256(0xA)), bytes32(uint256(1)));
        bytes32 before = reg.getRoot();
        reg.updateClaimLeaf(bytes32(uint256(0xA)), bytes32(uint256(999)));
        bytes32 afterRoot = reg.getRoot();
        vm.stopPrank();
        assertTrue(before != afterRoot, "update changed root");
        assertTrue(reg.isRootValid(afterRoot));
    }
}
