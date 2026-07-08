// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseProviderAdapter} from "./BaseProviderAdapter.sol";

/// @title ZkPassportAdapter
/// @notice Policy holder for the zkPassport provider on the shared ERC-7812 registry.
/// @dev Registrar address + root-validity window passed at deploy time (not hardcoded).
///      zkPassport roots are typically given a LONGER window (e.g. 180 days) than Rarimo.
contract ZkPassportAdapter is BaseProviderAdapter {
    constructor(address zkPassportRegistrar, uint256 rootValidityWindow_)
        BaseProviderAdapter(zkPassportRegistrar, rootValidityWindow_)
    {}
}
