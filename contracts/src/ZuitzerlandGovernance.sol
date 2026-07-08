// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {INullifierBanControl} from "./interfaces/INullifierBanControl.sol";

/// @title ZuitzerlandGovernance
/// @notice PoC ban mechanism. A single admin (owner) can ban / unban nullifiers,
///         which flips the flag in the gate. Banning a nullifier prevents the
///         corresponding member from gaining access on future proof submissions.
///
/// @dev The gate must point its `governance` to this contract
///      (gate.setGovernance(address(this))). Works with either the generic
///      `ZuitzerlandVerifier` (Path B) or the Rarimo `ZuitzPassExecutor` (Path A),
///      since both implement `INullifierBanControl`.
contract ZuitzerlandGovernance is Ownable {
    INullifierBanControl public immutable verifier;

    event NullifierBanned(bytes32 nullifier, address bannedBy, uint256 timestamp);
    event NullifierUnbanned(bytes32 nullifier, address unbannedBy, uint256 timestamp);

    constructor(address _verifier) Ownable(msg.sender) {
        verifier = INullifierBanControl(_verifier);
    }

    /// @notice Ban a nullifier. Only the admin (owner) may call.
    function banNullifier(bytes32 nullifier) external onlyOwner {
        verifier.setNullifierBanned(nullifier, true);
        emit NullifierBanned(nullifier, msg.sender, block.timestamp);
    }

    /// @notice Unban a nullifier. Only the admin (owner) may call.
    function unbanNullifier(bytes32 nullifier) external onlyOwner {
        verifier.setNullifierBanned(nullifier, false);
        emit NullifierUnbanned(nullifier, msg.sender, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // V2 (NOT IMPLEMENTED): vote-based governance.
    //
    // Replace the `onlyOwner` admin path above with a quorum mechanism where a
    // threshold of members — each proving membership via a ZK proof (Circuit 1)
    // and a distinct nullifier — can collectively trigger a ban. Likely shape:
    //   - proposeBan(bytes32 targetNullifier) opens a proposal
    //   - voteOnBan(proposalId, ZkProof) accumulates unique-nullifier votes
    //   - executeBan(proposalId) calls verifier.setNullifierBanned once quorum is met
    // Out of scope for the PoC.
    // -------------------------------------------------------------------------
}
