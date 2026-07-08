// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IClaimsRegistry} from "../interfaces/IClaimsRegistry.sol";

/// @notice The subset of ERC-20 / ERC-721 both expose — enough to gate on "holds ≥ N".
interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @title OnchainReadIssuer
/// @notice A zero-ZK issuer (ARCHITECTURE_UPDATED.md §2.4, §3 "public on-chain state") that turns
///         a public token holding into a claim — e.g. "holds the Zuitzerland membership NFT" or
///         "holds ≥ 100 GOV". The owner registers a `Condition` per claim type (token + minimum
///         balance); anyone may then trigger issuance for any account, since the underlying state
///         is public anyway.
///
/// @dev **No privacy — this links a wallet.** The subject is derived from the wallet address
///      (`keccak256("onchain", account)`), a DIFFERENT namespace from the personhood providers
///      (`"rarimo"` / `"worldid"`). So these claims compose in statements built over wallet
///      subjects; they do not silently merge with a passport nullifier's subject. That is the
///      §5 "surface the trade-off" stance: wallet-linked evidence is honestly wallet-scoped.
///
/// @dev On-chain balances change (the holder can sell), so conditions carry a `validity` window —
///      claims should be short-lived and re-issued, not permanent. The `ClaimsRegistry` must
///      permission this contract as an issuer of each configured claim type.
contract OnchainReadIssuer is Ownable {
    IClaimsRegistry public immutable claims;

    /// @dev Provider namespace for the layer subject `keccak256(PROVIDER_ID, account)`.
    string internal constant PROVIDER_ID = "onchain";

    struct Condition {
        address token; // ERC-20/ERC-721 read via balanceOf
        uint256 minBalance; // inclusive threshold (1 = "holds at least one")
        uint64 validity; // expiry window in seconds (0 = never expires)
        bool enabled;
    }

    /// @dev claimType => the on-chain condition that mints it.
    mapping(bytes32 => Condition) public conditions;

    event ConditionSet(bytes32 indexed claimType, address token, uint256 minBalance, uint64 validity);
    event ConditionRemoved(bytes32 indexed claimType);
    event Issued(bytes32 indexed subject, bytes32 indexed claimType, address indexed account);

    error ConditionNotSet(bytes32 claimType);
    error BalanceTooLow(address account, uint256 balance, uint256 minBalance);

    constructor(address owner_, IClaimsRegistry claims_) Ownable(owner_) {
        claims = claims_;
    }

    // -----------------------------------------------------------------------
    // Owner config
    // -----------------------------------------------------------------------
    function setCondition(bytes32 claimType, address token, uint256 minBalance, uint64 validity)
        external
        onlyOwner
    {
        conditions[claimType] =
            Condition({token: token, minBalance: minBalance, validity: validity, enabled: true});
        emit ConditionSet(claimType, token, minBalance, validity);
    }

    function removeCondition(bytes32 claimType) external onlyOwner {
        delete conditions[claimType];
        emit ConditionRemoved(claimType);
    }

    // -----------------------------------------------------------------------
    // Issuance
    // -----------------------------------------------------------------------
    /// @notice The wallet-linked subject a claim is issued to.
    function subjectOf(address account) public pure returns (bytes32) {
        return keccak256(abi.encode(PROVIDER_ID, account));
    }

    /// @notice Whether `account` currently satisfies `claimType`'s condition (view).
    function eligible(bytes32 claimType, address account) public view returns (bool) {
        Condition memory c = conditions[claimType];
        if (!c.enabled) return false;
        return IBalanceOf(c.token).balanceOf(account) >= c.minBalance;
    }

    /// @notice Read `account`'s public balance and, if it meets the threshold, issue the claim to
    ///         its wallet-linked subject. Permissionless — the evidence is public.
    function issueClaim(bytes32 claimType, address account) external {
        Condition memory c = conditions[claimType];
        if (!c.enabled) revert ConditionNotSet(claimType);

        uint256 bal = IBalanceOf(c.token).balanceOf(account);
        if (bal < c.minBalance) revert BalanceTooLow(account, bal, c.minBalance);

        uint64 expiry = c.validity == 0 ? 0 : uint64(block.timestamp) + c.validity;
        bytes32 subject = subjectOf(account);
        claims.issue(subject, claimType, expiry);
        emit Issued(subject, claimType, account);
    }
}
