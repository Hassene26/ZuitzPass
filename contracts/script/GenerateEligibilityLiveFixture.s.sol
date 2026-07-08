// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SmtFixtureWrapper} from "../test/fixtures/SmtFixtureWrapper.sol";

/// @notice Circuit-A (eligibility) fixture for the LIVE demo — a single `UNIQUE_HUMAN` claim, made
///         **gate-consistent** so `EligibilityGate.consume` accepts it. Assumes the on-chain
///         `ClaimsSMTRegistry` holds exactly the one leaf the redeem wrote (single-leaf tree ⇒
///         all-zero siblings, root = leaf hash), keyed by the SAME `secret` used in the issuance
///         fixture (424242) and the SAME `expiresAt`/`issuerId` the redeem used.
///
/// Emits `./eligibility_live_prover.toml` — copy to `../eligibility_proof/Prover.toml`, then
/// `nargo execute` + `bb prove … --oracle_hash keccak`.
///
/// Env:
///   EXPIRES_AT   (required)  — the expiry you passed to RedeemIssuer.redeem (unix seconds)
///   APP          (broadcaster / the address that will call gate.consume)
///   STATEMENT_ID (keccak("DEMO_HUMAN_ONLY"))
///   CONTEXT_ID   (202606)
///   NOW_TS       (block.timestamp — set ≈ when you'll submit; gate tolerance is 1h)
///   SIGNAL       (0)
///   ISSUER_ID    (1)  — must match the provider's issuerId used at redeem
contract GenerateEligibilityLiveFixture is Script {
    uint256 constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint32 constant TREE_DEPTH = 20;
    uint32 constant MAX_CLAIMS = 4;
    uint256 constant SECRET = 424242; // same identity as the issuance fixture

    struct F {
        bytes32 root;
        bytes32 nullifier;
        uint256 appId;
        uint256 contextId;
        uint256 nowTs;
        uint256 claimType;
        uint256 issuerId;
        uint256 expiresAt;
        uint256 signal;
    }

    function run() external {
        F memory f;
        f.expiresAt = vm.envUint("EXPIRES_AT");
        f.contextId = vm.envOr("CONTEXT_ID", uint256(202606));
        f.nowTs = vm.envOr("NOW_TS", block.timestamp);
        f.signal = vm.envOr("SIGNAL", uint256(0));
        f.issuerId = vm.envOr("ISSUER_ID", uint256(1));
        f.claimType = uint256(keccak256("UNIQUE_HUMAN")) % P;

        address app = vm.envOr("APP", msg.sender);
        bytes32 statementId = vm.envOr("STATEMENT_ID", keccak256("DEMO_HUMAN_ONLY"));

        SmtFixtureWrapper smt = new SmtFixtureWrapper(TREE_DEPTH);
        {
            bytes32 idc = smt.poseidon2(bytes32(SECRET), bytes32(0));
            bytes32 leafKey = smt.poseidon2(idc, bytes32(f.claimType));
            bytes32 value = smt.poseidon3(bytes32(f.issuerId), bytes32(f.expiresAt), bytes32(0));
            f.root = smt.poseidon3(leafKey, value, bytes32(uint256(1))); // single-leaf root = leaf hash
        }
        f.appId = uint256(keccak256(abi.encode(app, statementId))) % P;
        f.nullifier = smt.poseidon3(bytes32(SECRET), bytes32(f.appId), bytes32(f.contextId));

        _write(f);

        console2.log("wrote ./eligibility_live_prover.toml");
        console2.log("root:", vm.toString(f.root));
        console2.log("nullifier:", vm.toString(f.nullifier));
        console2.log("app_id:", f.appId);
        console2.log("register statement (allOf=[keccak UNIQUE_HUMAN], consumable), id:");
        console2.logBytes32(statementId);
    }

    function _write(F memory f) internal {
        string memory t = string.concat(
            _kv("secret", bytes32(SECRET)), "\n",
            _kv("signal", bytes32(f.signal)), "\n",
            _kv("root", f.root), "\n",
            _kv("nullifier", f.nullifier), "\n",
            _kv("app_id", bytes32(f.appId)), "\n",
            _kv("context_id", bytes32(f.contextId)), "\n",
            "now_ts = ", vm.toString(f.nowTs), "\n"
        );
        t = string.concat(
            t,
            'claim_types = ["', vm.toString(bytes32(f.claimType)), '", "0x0", "0x0", "0x0"]\n',
            'issuer_ids = ["', vm.toString(bytes32(f.issuerId)), '", "0x0", "0x0", "0x0"]\n',
            "expires_ats = [", vm.toString(f.expiresAt), ", 0, 0, 0]\n",
            _zeroSiblings()
        );
        vm.writeFile("./eligibility_live_prover.toml", t);
    }

    // siblings: MAX_CLAIMS x TREE_DEPTH, all zero (single-leaf tree + sentinel slots).
    function _zeroSiblings() internal pure returns (string memory t) {
        t = "siblings = [\n";
        for (uint256 i = 0; i < MAX_CLAIMS; i++) {
            t = string.concat(t, "  [");
            for (uint256 j = 0; j < TREE_DEPTH; j++) {
                t = string.concat(t, '"0x0"', j + 1 < TREE_DEPTH ? ", " : "");
            }
            t = string.concat(t, i + 1 < MAX_CLAIMS ? "],\n" : "]\n");
        }
        t = string.concat(t, "]\n");
    }

    function _kv(string memory key, bytes32 val) internal view returns (string memory) {
        return string.concat(key, ' = "', vm.toString(val), '"');
    }
}
