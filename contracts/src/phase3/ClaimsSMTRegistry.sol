// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RootedSMTRegistry} from "./RootedSMTRegistry.sol";

/// @title ClaimsSMTRegistry
/// @notice Phase-3 (unlinkable) claims spine — the on-chain SMT the eligibility circuit proves
///         against (contracts/PHASE3_UNLINKABLE_DESIGN.md §2). Leaves are
///         `key = Poseidon2(idc, claimType)`, `value = Poseidon3(issuerId, expiresAt, 0)` — opaque,
///         since `idc` hashes a private secret. A rooted SMT with root history (see
///         `RootedSMTRegistry`); its `writer` is called the **redeemer** here: the Circuit-B
///         private-redeem entrypoint (`RedeemIssuer`), or a trusted issuer for the PoC.
contract ClaimsSMTRegistry is RootedSMTRegistry {
    event ClaimLeafAdded(bytes32 indexed key, bytes32 value, bytes32 newRoot);
    event ClaimLeafUpdated(bytes32 indexed key, bytes32 value, bytes32 newRoot);

    error NotRedeemer();

    constructor(address owner_, uint32 maxDepth_, uint256 rootValidity_)
        RootedSMTRegistry(owner_, maxDepth_, rootValidity_)
    {}

    modifier onlyRedeemer() {
        if (msg.sender != writer) revert NotRedeemer();
        _;
    }

    /// @notice The address permitted to write claim leaves (alias of the rooted-SMT `writer`).
    function redeemer() external view returns (address) {
        return writer;
    }

    function setRedeemer(address redeemer_) external onlyOwner {
        _setWriter(redeemer_);
    }

    /// @notice Insert a new claim leaf and snapshot the resulting root into the history.
    function addClaimLeaf(bytes32 key, bytes32 value) external onlyRedeemer {
        emit ClaimLeafAdded(key, value, _insertLeaf(key, value));
    }

    /// @notice Update an existing claim leaf (e.g. renewal refreshes `expiresAt`).
    function updateClaimLeaf(bytes32 key, bytes32 value) external onlyRedeemer {
        emit ClaimLeafUpdated(key, value, _updateLeaf(key, value));
    }
}
