// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RedeemIssuer} from "../src/phase3/RedeemIssuer.sol";
import {ClaimsSMTRegistry} from "../src/phase3/ClaimsSMTRegistry.sol";
import {VerifiedHumansTree} from "../src/phase3/VerifiedHumansTree.sol";
import {IHonkVerifier} from "../src/phase3/interfaces/IHonkVerifier.sol";

import {MockEligibilityVerifier} from "./mocks/EligibilityMocks.sol";

contract RedeemIssuerTest is Test {
    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    RedeemIssuer internal redeemer;
    ClaimsSMTRegistry internal claimsSmt;
    VerifiedHumansTree internal vht;
    MockEligibilityVerifier internal verifier;

    bytes32 internal constant PROVIDER = keccak256("worldid");
    uint256 internal claimType = uint256(keccak256("UNIQUE_HUMAN")) % P;
    uint256 internal constant ISSUER = 0x1D;
    bytes32 internal constant LEAF_KEY = keccak256("alice-idc-human-leafkey");
    uint256 internal constant REDEEM_NULL = 0xBEEF;
    bytes32 internal credRoot;

    function setUp() public {
        vm.warp(1_900_000_000);
        claimsSmt = new ClaimsSMTRegistry(address(this), 20, 1 hours);
        vht = new VerifiedHumansTree(address(this), 20, 1 hours);
        verifier = new MockEligibilityVerifier();
        redeemer = new RedeemIssuer(address(this), IHonkVerifier(address(verifier)), claimsSmt, 180 days);

        // The redeem entrypoint is the claims tree's writer.
        claimsSmt.setRedeemer(address(redeemer));

        // Part A: an inserter puts a credential into the verified-humans tree.
        vht.setWriter(address(this));
        vht.insertCredential(keccak256("credential-C"));
        credRoot = vht.getRoot();

        redeemer.registerProvider(PROVIDER, vht, claimType, ISSUER);
    }

    function _pub(bytes32 root, uint256 ct, bytes32 leafKey, uint256 rn) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](4);
        p[0] = root;
        p[1] = bytes32(ct);
        p[2] = leafKey;
        p[3] = bytes32(rn);
    }

    function _exp() internal view returns (uint64) {
        return uint64(block.timestamp + 30 days);
    }

    function test_Redeem_WritesClaimLeaf() public {
        redeemer.redeem(PROVIDER, _exp(), "", _pub(credRoot, claimType, LEAF_KEY, REDEEM_NULL));

        assertTrue(redeemer.consumedRedeemNullifier(REDEEM_NULL), "nullifier consumed");
        assertTrue(claimsSmt.getRoot() != bytes32(0), "claims root advanced");
        assertTrue(claimsSmt.getProof(LEAF_KEY).existence, "claim leaf written");
    }

    function test_Redeem_Replay_Reverts() public {
        bytes32[] memory p = _pub(credRoot, claimType, LEAF_KEY, REDEEM_NULL);
        redeemer.redeem(PROVIDER, _exp(), "", p);
        // A second redeem of the same credential (same redeem_nullifier) reverts.
        bytes32[] memory p2 = _pub(credRoot, claimType, keccak256("other-leaf"), REDEEM_NULL);
        vm.expectRevert(abi.encodeWithSelector(RedeemIssuer.AlreadyRedeemed.selector, REDEEM_NULL));
        redeemer.redeem(PROVIDER, _exp(), "", p2);
    }

    function test_Redeem_BadProof_Reverts() public {
        bytes32[] memory p = _pub(credRoot, claimType, LEAF_KEY, REDEEM_NULL);
        verifier.setResult(false);
        vm.expectRevert(RedeemIssuer.ProofInvalid.selector);
        redeemer.redeem(PROVIDER, _exp(), "", p);
    }

    function test_Redeem_StaleCredRoot_Reverts() public {
        bytes32 stale = bytes32(uint256(0xDEAD));
        bytes32[] memory p = _pub(stale, claimType, LEAF_KEY, REDEEM_NULL);
        vm.expectRevert(abi.encodeWithSelector(RedeemIssuer.StaleCredRoot.selector, stale));
        redeemer.redeem(PROVIDER, _exp(), "", p);
    }

    function test_Redeem_WrongClaimType_Reverts() public {
        uint256 wrong = uint256(keccak256("OVER_18")) % P;
        bytes32[] memory p = _pub(credRoot, wrong, LEAF_KEY, REDEEM_NULL);
        vm.expectRevert(abi.encodeWithSelector(RedeemIssuer.ClaimTypeNotAllowed.selector, wrong, claimType));
        redeemer.redeem(PROVIDER, _exp(), "", p);
    }

    function test_Redeem_ExpiryTooLong_Reverts() public {
        bytes32[] memory p = _pub(credRoot, claimType, LEAF_KEY, REDEEM_NULL);
        uint64 tooLong = uint64(block.timestamp + 181 days); // > maxValidity
        vm.expectRevert(abi.encodeWithSelector(RedeemIssuer.BadExpiry.selector, tooLong));
        redeemer.redeem(PROVIDER, tooLong, "", p);
    }

    function test_Redeem_ExpiryInPast_Reverts() public {
        bytes32[] memory p = _pub(credRoot, claimType, LEAF_KEY, REDEEM_NULL);
        uint64 past = uint64(block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(RedeemIssuer.BadExpiry.selector, past));
        redeemer.redeem(PROVIDER, past, "", p);
    }

    function test_Redeem_ProviderDisabled_Reverts() public {
        redeemer.setProviderEnabled(PROVIDER, false);
        bytes32[] memory p = _pub(credRoot, claimType, LEAF_KEY, REDEEM_NULL);
        vm.expectRevert(abi.encodeWithSelector(RedeemIssuer.ProviderNotEnabled.selector, PROVIDER));
        redeemer.redeem(PROVIDER, _exp(), "", p);
    }
}
