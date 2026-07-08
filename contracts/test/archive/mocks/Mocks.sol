// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEvidenceRegistry, INoirVerifier} from "../../src/interfaces/IZuitzerland.sol";

/// @notice Mock ERC-7812 registry: lets tests set a root's registration timestamp.
contract MockEvidenceRegistry is IEvidenceRegistry {
    mapping(bytes32 => uint256) public timestamps;

    function setRootTimestamp(bytes32 root, uint256 ts) external {
        timestamps[root] = ts;
    }

    function getRootTimestamp(bytes32 root) external view returns (uint256) {
        return timestamps[root];
    }
}

/// @notice Mock Noir verifier: returns a configurable verdict.
contract MockNoirVerifier is INoirVerifier {
    bool public verdict = true;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function verifyProof(bytes calldata, bytes32[] calldata) external view returns (bool) {
        return verdict;
    }
}

/// @notice Mock BB-style HonkVerifier exposing `verify` (not `verifyProof`),
///         used to test NoirVerifierWrapper's translation.
contract MockHonkVerifier {
    bool public verdict = true;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function verify(bytes calldata, bytes32[] calldata) external view returns (bool) {
        return verdict;
    }
}
