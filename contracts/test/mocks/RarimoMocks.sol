// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoseidonSMT} from "../../src/rarimo/interfaces/state/IPoseidonSMT.sol";

/// @notice Mock of the registration SMT / RegistrationSMTReplicator freshness surface.
contract MockRegistrationSMT is IPoseidonSMT {
    uint256 public constant ROOT_VALIDITY = 1 hours;

    bool public allValid = true;
    mapping(bytes32 => bool) public valid;

    function setAllValid(bool v_) external {
        allValid = v_;
    }

    function setRootValid(bytes32 root_, bool v_) external {
        valid[root_] = v_;
    }

    function isRootValid(bytes32 root_) external view returns (bool) {
        return allValid || valid[root_];
    }
}

/// @notice Mock of the Groth16 `TD3QueryProofVerifier`. Its `verifyProof` signature must match
///         what `AQueryProofExecutor._verifyCircomProof` staticcalls:
///         `verifyProof(uint256[2],uint256[2][2],uint256[2],uint256[23])`.
/// @dev MUST be `view` — the executor calls it via STATICCALL.
contract MockQueryVerifier {
    bool public result;

    constructor(bool result_) {
        result = result_;
    }

    function setResult(bool result_) external {
        result = result_;
    }

    function verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[23] calldata
    ) external view returns (bool) {
        return result;
    }
}
