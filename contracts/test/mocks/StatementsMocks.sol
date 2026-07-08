// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IClaimsRegistry, Claim} from "../../src/interfaces/IClaimsRegistry.sol";

/// @notice Recording stub of `IClaimsRegistry` for issuer-hook unit tests: it captures every
///         `issue(...)` call so a test can assert the exact (subject, claimType, expiry) the gate
///         emitted, without pulling in the real registry's permissioning/expiry logic.
contract MockClaimsRegistry is IClaimsRegistry {
    struct Issued {
        bytes32 subject;
        bytes32 claimType;
        uint64 expiresAt;
    }

    Issued[] public issued;

    function issueCount() external view returns (uint256) {
        return issued.length;
    }

    function issuedAt(uint256 i) external view returns (Issued memory) {
        return issued[i];
    }

    // -- the only call the gates make --
    function issue(bytes32 subject, bytes32 claimType, uint64 expiresAt) external override {
        issued.push(Issued({subject: subject, claimType: claimType, expiresAt: expiresAt}));
    }

    function hasValidClaim(bytes32 subject, bytes32 claimType) external view override returns (bool) {
        for (uint256 i = 0; i < issued.length; ++i) {
            if (issued[i].subject == subject && issued[i].claimType == claimType) return true;
        }
        return false;
    }

    // -- unused interface surface (stubs) --
    function registerClaimType(bytes32, string calldata) external override {}
    function setIssuer(bytes32, address, bool) external override {}
    function revoke(bytes32, bytes32) external override {}
    function getClaim(bytes32, bytes32) external view override returns (Claim memory c) {
        return c;
    }
    function setNullifierBanned(bytes32, bool) external override {}
}

/// @notice Minimal `balanceOf` token (stands in for ERC-20/ERC-721) for OnchainReadIssuer tests.
contract MockBalanceToken {
    mapping(address => uint256) public balanceOf;

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }
}
