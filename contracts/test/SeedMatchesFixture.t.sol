// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {VerifiedHumansTree} from "../src/phase3/VerifiedHumansTree.sol";

/// @notice Confirms that seeding a VerifiedHumansTree the way SeedVerifiedHumans.s.sol does
///         (credential C + 6 decoys, value = 1, via insertCredential) reproduces the exact
///         `cred_root` the Circuit-B fixture (GenerateIssuanceFixture) was built against — so the
///         live redeem won't revert `StaleCredRoot`. Update the expected root if the generator's
///         constants change.
contract SeedMatchesFixtureTest is Test {
    bytes32 constant EXPECTED_CRED_ROOT = 0x0f205d5130082e6d47ec46220a5f495bc6d84e89b17b320a2e95a454123737af;

    function test_SeedRoot_MatchesFixtureCredRoot() public {
        VerifiedHumansTree vht = new VerifiedHumansTree(address(this), 20, 1 hours);
        vht.setWriter(address(this));

        vht.insertCredential(bytes32(PoseidonT3.hash([uint256(424242), uint256(987654321)]))); // C
        for (uint256 i = 1; i <= 6; i++) {
            vht.insertCredential(bytes32(PoseidonT3.hash([uint256(0xDEC0) + i, uint256(0)])));
        }

        assertEq(vht.getRoot(), EXPECTED_CRED_ROOT, "seed root must equal the fixture cred_root");
    }
}
