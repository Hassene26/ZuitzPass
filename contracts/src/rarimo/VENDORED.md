# Vendored Rarimo SDK

These files are copied **verbatim** from
[`rarimo/passport-contracts`](https://github.com/rarimo/passport-contracts) at commit
`75a82ceca7aeb83b84deec35cfe58c7a0d32d919`, so `ZuitzPassExecutor` can compile against the
real query-proof SDK inside this Foundry project (the upstream repo is Hardhat-based).

Do **not** hand-edit these. To update, re-copy from upstream at a pinned commit and bump the
hash above.

| Vendored file | Upstream path |
|---|---|
| `sdk/AQueryProofExecutor.sol` | `contracts/sdk/AQueryProofExecutor.sol` |
| `sdk/lib/PublicSignalsBuilder.sol` | `contracts/sdk/lib/PublicSignalsBuilder.sol` |
| `sdk/lib/PublicSignalsTD1Builder.sol` | `contracts/sdk/lib/PublicSignalsTD1Builder.sol` |
| `interfaces/verifiers/INoirVerifier.sol` | `contracts/interfaces/verifiers/INoirVerifier.sol` |
| `interfaces/state/IPoseidonSMT.sol` | `contracts/interfaces/state/IPoseidonSMT.sol` |
| `utils/Date2Time.sol` | `contracts/utils/Date2Time.sol` |
| `sdk/verifier/TD3QueryProofVerifier.sol` | `contracts/sdk/verifier/TD3QueryProofVerifier.sol` |

`TD3QueryProofVerifier` is the Groth16 verifier for the Query circuit
(`verifyProof(uint256[2],uint256[2][2],uint256[2],uint256[23])`). Rarimo publishes **no
canonical deployment** — deploying your own is the documented pattern (see the on-chain
verification guide); `DeployRarimo.s.sol` deploys a fresh instance.

✅ **VK confirmed against production (2026-07-03):** every constant (alpha/beta/gamma/delta +
IC0…IC23) equals the Groth16 verification key in `rarimo/verificator-svc`
`proof_keys/passport.json` (main; last rotated 2024-09-11) — the key Rarimo's production
off-chain verifier uses for live RariMe query proofs. Re-check if Rarimo rotates the circuit.

The **`RegistrationSMTReplicator`** is NOT vendored — we deploy on Rarimo L2 (chainId 7368)
where the source `RegistrationSMT` (`0x479F84…A879`) already lives, so no replicator is needed.
