// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseProviderAdapter} from "./BaseProviderAdapter.sol";

/// @title RarimoAdapter
/// @notice Policy holder for the Rarimo provider on the shared ERC-7812 registry.
/// @dev Registrar address + root-validity window passed at deploy time (not hardcoded).
///      Rarimo roots are typically given a SHORTER window (e.g. 7 days) than zkPassport.
contract RarimoAdapter is BaseProviderAdapter {
    constructor(address rarimoRegistrar, uint256 rootValidityWindow_)
        BaseProviderAdapter(rarimoRegistrar, rootValidityWindow_)
    {}
}
