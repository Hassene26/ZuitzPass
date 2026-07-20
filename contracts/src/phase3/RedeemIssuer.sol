// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoseidonT4} from "poseidon-solidity/PoseidonT4.sol";

import {IHonkVerifier} from "./interfaces/IHonkVerifier.sol";
import {ClaimsSMTRegistry} from "./ClaimsSMTRegistry.sol";
import {VerifiedHumansTree} from "./VerifiedHumansTree.sol";

/// @title RedeemIssuer
/// @notice Part-B entrypoint of Phase-3 strong private binding (contracts/PHASE3_UNLINKABLE_DESIGN.md
///         §4/§4.1). Verifies a Circuit-B proof and writes an opaque claim leaf into the
///         `ClaimsSMTRegistry` — without learning `idc`, the credential `C`, or the provider
///         nullifier. This contract is set as the claims tree's `redeemer` (writer).
///
///         Flow: a human proves (Circuit B) that they own a credential in a provider's
///         `VerifiedHumansTree` and correctly derived `leaf_key = Poseidon2(idc, claimType)` and a
///         single-use `redeem_nullifier`. This entrypoint then checks provider permissioning + root
///         freshness + expiry policy, consumes the nullifier once, and writes
///         `claimsSmt.addClaimLeaf(leaf_key, Poseidon3(issuerId, expiresAt, 0))`.
///
///         Renewal (§4.1 revocation model): once a claim lapses, `renew` accepts a fresh Circuit-B
///         proof against the provider's *current* cred_root re-deriving the same
///         (leaf_key, redeem_nullifier) pair and refreshes the leaf via `updateClaimLeaf` —
///         revoked humans (rotated out of the tree) cannot renew.
///
/// @dev The claim leaf value is `Poseidon3(issuerId, expiresAt, 0)` — the exact commitment the
///      eligibility circuit (Circuit A) expects. `issuerId` / `expiresAt` are public (provider
///      config + this tx), so the holder can rebuild their Circuit-A witness.
contract RedeemIssuer is Ownable {
    /// @dev Circuit-B public inputs: [cred_root, claim_type, leaf_key, redeem_nullifier].
    uint256 internal constant N_PUB = 4;

    IHonkVerifier public immutable verifier; // Circuit-B UltraHonk verifier
    ClaimsSMTRegistry public immutable claimsSmt; // must set this contract as its redeemer

    /// @dev Max claim lifetime (seconds) — a redeemed claim can't outlive this window.
    uint256 public maxValidity;

    struct Provider {
        VerifiedHumansTree credTree; // per-provider verified-humans anonymity-set tree
        uint256 claimType; // canonical keccak(name) mod p — the only type this provider may mint
        uint256 issuerId; // written into the claim leaf value (and Alice's Circuit-A witness)
        bool enabled;
        uint256 maxValidity; // per-provider override (0 = use the global `maxValidity`)
    }

    mapping(bytes32 => Provider) public providers;
    mapping(uint256 => bool) public consumedRedeemNullifier;
    /// @dev redeem_nullifier => the claim leaf key it minted. Renewal must present a fresh
    ///      Circuit-B proof that re-derives the *same* (leaf_key, redeem_nullifier) pair — same
    ///      `(s, r, claimType)` — so only the original credential holder can refresh the leaf.
    mapping(uint256 => bytes32) public redeemedLeafKey;

    event ProviderRegistered(bytes32 indexed providerId, address credTree, uint256 claimType, uint256 issuerId);
    event ProviderEnabled(bytes32 indexed providerId, bool enabled);
    event MaxValidityUpdated(uint256 maxValidity);
    event ProviderMaxValidityUpdated(bytes32 indexed providerId, uint256 maxValidity);
    event ClaimRedeemed(bytes32 indexed providerId, bytes32 leafKey, uint256 redeemNullifier, uint64 expiresAt);
    event ClaimRenewed(bytes32 indexed providerId, bytes32 leafKey, uint256 redeemNullifier, uint64 expiresAt);

    error ProviderNotEnabled(bytes32 providerId);
    error BadPublicInputLength(uint256 got);
    error ProofInvalid();
    error ClaimTypeNotAllowed(uint256 got, uint256 expected);
    error StaleCredRoot(bytes32 credRoot);
    error BadExpiry(uint64 expiresAt);
    error AlreadyRedeemed(uint256 redeemNullifier);
    error NotRedeemed(uint256 redeemNullifier);
    error LeafKeyMismatch(bytes32 got, bytes32 expected);

    constructor(address owner_, IHonkVerifier verifier_, ClaimsSMTRegistry claimsSmt_, uint256 maxValidity_)
        Ownable(owner_)
    {
        verifier = verifier_;
        claimsSmt = claimsSmt_;
        maxValidity = maxValidity_ == 0 ? 180 days : maxValidity_;
    }

    // -----------------------------------------------------------------------
    // Governance
    // -----------------------------------------------------------------------
    function registerProvider(bytes32 providerId, VerifiedHumansTree credTree, uint256 claimType, uint256 issuerId)
        external
        onlyOwner
    {
        providers[providerId] = Provider({
            credTree: credTree,
            claimType: claimType,
            issuerId: issuerId,
            enabled: true,
            maxValidity: 0
        });
        emit ProviderRegistered(providerId, address(credTree), claimType, issuerId);
    }

    function setProviderEnabled(bytes32 providerId, bool enabled) external onlyOwner {
        providers[providerId].enabled = enabled;
        emit ProviderEnabled(providerId, enabled);
    }

    function setMaxValidity(uint256 maxValidity_) external onlyOwner {
        maxValidity = maxValidity_;
        emit MaxValidityUpdated(maxValidity_);
    }

    /// @notice Per-provider max claim lifetime (docs/PRIVATE_PROVABILITY_FRAMEWORK.md §B.3) —
    ///         e.g. durable facts like event attendance can outlive the global 180-day default.
    ///         `0` falls back to the global `maxValidity`.
    function setProviderMaxValidity(bytes32 providerId, uint256 maxValidity_) external onlyOwner {
        providers[providerId].maxValidity = maxValidity_;
        emit ProviderMaxValidityUpdated(providerId, maxValidity_);
    }

    // -----------------------------------------------------------------------
    // Redeem (anyone with a valid Circuit-B proof; typically Alice via a relayer)
    // -----------------------------------------------------------------------
    /// @param providerId which provider's credential is being redeemed.
    /// @param expiresAt   the claim's expiry (policy: `now < expiresAt <= now + maxValidity`).
    /// @param proof       the Circuit-B proof.
    /// @param pub         [cred_root, claim_type, leaf_key, redeem_nullifier].
    function redeem(bytes32 providerId, uint64 expiresAt, bytes calldata proof, bytes32[] calldata pub) external {
        Provider memory pr = _checkProof(providerId, expiresAt, proof, pub);

        uint256 rn = uint256(pub[3]);
        if (consumedRedeemNullifier[rn]) revert AlreadyRedeemed(rn);
        consumedRedeemNullifier[rn] = true;
        redeemedLeafKey[rn] = pub[2];

        claimsSmt.addClaimLeaf(pub[2], _leafValue(pr, expiresAt));
        emit ClaimRedeemed(providerId, pub[2], rn, expiresAt);
    }

    // -----------------------------------------------------------------------
    // Renew (PHASE3_UNLINKABLE_DESIGN.md §4.1 revocation model)
    // -----------------------------------------------------------------------
    /// @notice Refresh an already-redeemed claim leaf's `expiresAt`. The holder must present a
    ///         *fresh* Circuit-B proof against the provider's **current** `cred_root` — this is the
    ///         §4.1 revocation mechanism: a provider drops a revoked human by rotating its
    ///         credential tree, and that human can then no longer renew once their claim lapses.
    ///         Circuit B is deterministic in `(s, r, claimType)`, so the proof re-derives the same
    ///         `redeem_nullifier` and `leaf_key`; we require both to match the original redeem,
    ///         which makes renewal restricted to the credential that minted the leaf — no new
    ///         nullifier space and no circuit change.
    function renew(bytes32 providerId, uint64 expiresAt, bytes calldata proof, bytes32[] calldata pub) external {
        Provider memory pr = _checkProof(providerId, expiresAt, proof, pub);

        uint256 rn = uint256(pub[3]);
        bytes32 mintedKey = redeemedLeafKey[rn];
        if (mintedKey == bytes32(0)) revert NotRedeemed(rn);
        if (mintedKey != pub[2]) revert LeafKeyMismatch(pub[2], mintedKey);

        claimsSmt.updateClaimLeaf(pub[2], _leafValue(pr, expiresAt));
        emit ClaimRenewed(providerId, pub[2], rn, expiresAt);
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------
    /// @dev Shared redeem/renew gate: provider enabled, proof valid, claim type permitted,
    ///      cred_root fresh, expiry within the provider's (or global) max validity window.
    function _checkProof(bytes32 providerId, uint64 expiresAt, bytes calldata proof, bytes32[] calldata pub)
        internal
        view
        returns (Provider memory pr)
    {
        pr = providers[providerId];
        if (!pr.enabled) revert ProviderNotEnabled(providerId);
        if (pub.length != N_PUB) revert BadPublicInputLength(pub.length);
        if (!verifier.verify(proof, pub)) revert ProofInvalid();

        // pub: [0]cred_root [1]claim_type [2]leaf_key [3]redeem_nullifier
        if (uint256(pub[1]) != pr.claimType) revert ClaimTypeNotAllowed(uint256(pub[1]), pr.claimType);
        if (!pr.credTree.isRootValid(pub[0])) revert StaleCredRoot(pub[0]);

        uint256 window = pr.maxValidity == 0 ? maxValidity : pr.maxValidity;
        if (expiresAt <= block.timestamp || expiresAt > block.timestamp + window) revert BadExpiry(expiresAt);
    }

    /// @dev Claim leaf value = Poseidon3(issuerId, expiresAt, 0) — the commitment Circuit A expects.
    function _leafValue(Provider memory pr, uint64 expiresAt) internal pure returns (bytes32) {
        return bytes32(PoseidonT4.hash([pr.issuerId, uint256(expiresAt), uint256(0)]));
    }
}
