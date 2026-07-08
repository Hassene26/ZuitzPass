// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ClaimsRegistry} from "../src/ClaimsRegistry.sol";
import {StatementRegistry} from "../src/StatementRegistry.sol";
import {AttestorIssuer} from "../src/issuers/AttestorIssuer.sol";
import {OnchainReadIssuer} from "../src/issuers/OnchainReadIssuer.sol";
import {ZuitzerlandGovernance} from "../src/ZuitzerlandGovernance.sol";
import {SubsidyPool} from "../src/demo/SubsidyPool.sol";
import {DemoToken} from "../src/demo/DemoToken.sol";
import {IClaimsRegistry} from "../src/interfaces/IClaimsRegistry.sol";
import {IStatementRegistry, Statement} from "../src/interfaces/IStatementRegistry.sol";

/// @notice Local (anvil) one-shot deploy for the browser demo. Deploys the statements layer with
///         the two ZERO-ZK issuers (no proofs needed in a browser), wires a statement
///         "attended AND holds the membership NFT", and a funded SubsidyPool. Writes every address
///         to `frontend/addresses.json` for the static frontend to load.
///
///         The demo uses the wallet-linked subject (`OnchainReadIssuer.subjectOf(wallet)`) for
///         everything, so the attestor attests to that same subject and the claims compose. The
///         ZK gates (ZuitzPassExecutor / WorldIDGate) plug in as additional issuers exactly the
///         same way — they're just impractical to drive from a browser.
///
/// Run: forge script script/DeployDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///        --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract DeployDemo is Script {
    bytes32 internal constant ATTENDEE = keccak256("ZUITZ_MAY25_ATTENDEE");
    bytes32 internal constant HOLDS_NFT = keccak256("HOLDS_ZUITZ_NFT");
    bytes32 internal constant DEMO_STATEMENT = keccak256("DEMO_ALPS_RESIDENCY");

    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender; // owner + organizer + attestor signer for the demo

        ClaimsRegistry claims = new ClaimsRegistry(deployer);
        StatementRegistry statements =
            new StatementRegistry(deployer, IClaimsRegistry(address(claims)));
        AttestorIssuer attestor = new AttestorIssuer(deployer, IClaimsRegistry(address(claims)));
        OnchainReadIssuer onchain = new OnchainReadIssuer(deployer, IClaimsRegistry(address(claims)));
        DemoToken token = new DemoToken();

        ZuitzerlandGovernance gov = new ZuitzerlandGovernance(address(claims));
        claims.setGovernance(address(gov));

        // Claim types + issuer permissions.
        claims.registerClaimType(ATTENDEE, "demo:attended-zuitzerland-may-2025");
        claims.registerClaimType(HOLDS_NFT, "demo:holds-membership-nft");
        claims.setIssuer(ATTENDEE, address(attestor), true);
        claims.setIssuer(HOLDS_NFT, address(onchain), true);

        attestor.setSigner(deployer, true);
        onchain.setCondition(HOLDS_NFT, address(token), 1, 7 days);

        // Statement: attended AND holds the membership NFT, consumable (one subsidy per epoch).
        bytes32[] memory allOf = new bytes32[](2);
        allOf[0] = ATTENDEE;
        allOf[1] = HOLDS_NFT;
        statements.registerStatement(
            DEMO_STATEMENT,
            Statement({
                allOf: allOf,
                anyOf: new bytes32[](0),
                consumable: true,
                metadataURI: "demo:alps-residency"
            })
        );

        // Funded pool paying 0.1 ETH per claim, epoch = 1 hour (short, so the demo can roll epochs).
        SubsidyPool pool =
            new SubsidyPool(deployer, IStatementRegistry(address(statements)), DEMO_STATEMENT, 0.1 ether, 1 hours);
        pool.fund{value: 5 ether}();

        vm.stopBroadcast();

        _writeAddresses(claims, statements, attestor, onchain, token, gov, pool);

        console.log("ClaimsRegistry:   ", address(claims));
        console.log("StatementRegistry:", address(statements));
        console.log("AttestorIssuer:   ", address(attestor));
        console.log("OnchainReadIssuer:", address(onchain));
        console.log("DemoToken:        ", address(token));
        console.log("SubsidyPool:      ", address(pool));
        console.log("-> wrote frontend/addresses.json");
    }

    function _writeAddresses(
        ClaimsRegistry claims,
        StatementRegistry statements,
        AttestorIssuer attestor,
        OnchainReadIssuer onchain,
        DemoToken token,
        ZuitzerlandGovernance gov,
        SubsidyPool pool
    ) internal {
        string memory j = "demo";
        vm.serializeAddress(j, "claimsRegistry", address(claims));
        vm.serializeAddress(j, "statementRegistry", address(statements));
        vm.serializeAddress(j, "attestorIssuer", address(attestor));
        vm.serializeAddress(j, "onchainReadIssuer", address(onchain));
        vm.serializeAddress(j, "demoToken", address(token));
        vm.serializeAddress(j, "governance", address(gov));
        vm.serializeAddress(j, "subsidyPool", address(pool));
        vm.serializeBytes32(j, "statementId", DEMO_STATEMENT);
        vm.serializeBytes32(j, "attendeeClaimType", ATTENDEE);
        string memory out = vm.serializeBytes32(j, "holdsNftClaimType", HOLDS_NFT);
        vm.writeJson(out, "./frontend/addresses.json");
    }
}
