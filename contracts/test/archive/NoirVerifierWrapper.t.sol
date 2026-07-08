// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NoirVerifierWrapper} from "../src/NoirVerifierWrapper.sol";
import {MockHonkVerifier} from "./mocks/Mocks.sol";

contract NoirVerifierWrapperTest is Test {
    MockHonkVerifier honk;
    NoirVerifierWrapper wrapper;

    function setUp() public {
        honk = new MockHonkVerifier();
        wrapper = new NoirVerifierWrapper(address(honk));
    }

    function test_ForwardsTrue() public view {
        bytes32[] memory inputs = new bytes32[](3);
        assertTrue(wrapper.verifyProof(hex"00", inputs));
    }

    function test_ForwardsFalse() public {
        honk.setVerdict(false);
        bytes32[] memory inputs = new bytes32[](3);
        assertFalse(wrapper.verifyProof(hex"00", inputs));
    }
}
