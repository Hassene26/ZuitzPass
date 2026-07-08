// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title DemoToken
/// @notice A throwaway `balanceOf` token for the local demo — stands in for the "Zuitzerland
///         membership NFT" the `OnchainReadIssuer` gates on. Mint is permissionless ON PURPOSE:
///         this is a demo prop, not a real asset. Do not deploy to a real network.
contract DemoToken {
    string public constant name = "Zuitzerland Membership (DEMO)";
    string public constant symbol = "ZUITZ-DEMO";

    mapping(address => uint256) public balanceOf;

    event Minted(address indexed to, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Minted(to, amount);
    }
}
