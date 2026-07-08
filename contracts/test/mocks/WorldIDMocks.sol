// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IWorldID} from "../../src/interfaces/IWorldID.sol";

/// @notice Mock World ID Router. `verifyProof` is `view` (called via STATICCALL) and reverts
///         when `willRevert` is set — standing in for an invalid proof.
contract MockWorldID is IWorldID {
    bool public willRevert;

    function setWillRevert(bool v_) external {
        willRevert = v_;
    }

    function verifyProof(
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256[8] calldata
    ) external view {
        if (willRevert) revert("MockWorldID: invalid proof");
    }
}
