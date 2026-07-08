// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IProviderAdapter} from "../interfaces/IZuitzerland.sol";

/// @title BaseProviderAdapter
/// @notice Per-provider policy holder for the SINGLE shared ERC-7812 registry.
///
/// @dev ERC-7812 is a singleton registry with one global SMT and one global root.
///      Providers are NOT separate registries — each provider has a `Registrar`
///      contract, and its statements live in the global tree at the isolated key
///      `getIsolatedKey(registrar, key)`. So this adapter does not point at a
///      registry; it carries:
///        - `registrar`           : the provider's registrar address (proof-bound)
///        - `rootValidityWindow`  : the provider's freshness policy (seconds)
///      Both are constructor args — never hardcoded — so each provider can set how
///      long its roots stay valid (e.g. zkPassport 180 days, Rarimo 7 days).
abstract contract BaseProviderAdapter is IProviderAdapter {
    /// @notice The provider's ERC-7812 registrar (the `source` in getIsolatedKey).
    address public immutable registrar;

    /// @notice Max age (seconds) of the global root accepted for this provider.
    uint256 public immutable rootValidityWindow;

    error InvalidRegistrar();
    error InvalidValidityWindow();

    constructor(address _registrar, uint256 _rootValidityWindow) {
        if (_registrar == address(0)) revert InvalidRegistrar();
        if (_rootValidityWindow == 0) revert InvalidValidityWindow();
        registrar = _registrar;
        rootValidityWindow = _rootValidityWindow;
    }
}
