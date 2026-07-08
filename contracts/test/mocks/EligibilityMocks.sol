// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEligibilityVerifier} from "../../src/phase3/interfaces/IEligibilityVerifier.sol";

/// @notice Stand-in for the Barretenberg UltraHonk verifier: returns a settable result so gate-logic
///         tests exercise decode/checks/consume without a real proof. Real ZK verification is
///         validated separately by `nargo`/`bb`.
contract MockEligibilityVerifier is IEligibilityVerifier {
    bool public result = true;

    function setResult(bool result_) external {
        result = result_;
    }

    function verify(bytes calldata, bytes32[] calldata) external view override returns (bool) {
        return result;
    }
}
