# Zuitzerland — Project Status

_Last updated: 2026-06-10_

Zuitzerland is a privacy-preserving, gated anonymous forum with on-chain governance,
built on **ERC-7812** (a singleton ZK identity registry using a Sparse Merkle Tree).
Users prove membership via ZK proofs without revealing their identity.

This file tracks what is built, what works, and what remains.

---

## High-level architecture

```
Circuit 1 (Noir)            Smart contracts (Solidity)              External
─────────────────           ──────────────────────────             ─────────────
membership_proof/           contracts/                             ERC-7812 registry
  • prove SMT membership       • ZuitzerlandVerifier (gate)           (singleton, shared)
  • derive nullifier           • ZuitzerlandGovernance (bans)         provider Registrars
  • expose session binding     • Rarimo/ZkPassport adapters           Noir UltraHonk verifier
                               • NoirVerifierWrapper
```

Public-input contract (LOCKED, 4 inputs): **`[root, nullifier, sessionBinding, registrar]`**

---

## ✅ Done

### Circuit 1 — `membership_proof/` (Noir)
- [x] Membership proof circuit (`src/main.nr`): commitment, ERC-7812 isolated-key SMT
      inclusion (depth 20, Poseidon), nullifier derivation, session-binding pass-through.
- [x] **4-input public interface** `[root, nullifier, session_binding, registrar]`
      (locked, matches the contracts). Fixed an earlier bug that emitted `session_binding`
      twice.
- [x] **ERC-7812 isolated keys**: `leaf_key = Poseidon2(registrar, Poseidon2(secret,0))`,
      leaf = `Poseidon3(key, value, 1)`, variable-depth reconstruction matching
      dl-solarity `SparseMerkleTree._processProof`.
- [x] Tests: happy path, other-witness, bad-root (should_fail), wrong-registrar
      (should_fail), Poseidon cross-check print.
- [x] **Check 1 PASSED** — Noir `bn254::hash_2` == iden3/circomlib Poseidon (verified via
      test vector `0x115cc0…`).
- [x] **Check 2 PASSED** — circuit `compute_root` reproduces the REAL dl-solarity SMT root
      on a multi-leaf fixture (`nargo execute` passed). Circuit ↔ on-chain SMT agree.
- [x] Docs: `HANDOFF.md`, `CIRCUIT1_ISOLATED_KEY_NOTE.md`.
- [x] **Verifier re-exported** — `target/Verifier.sol` regenerated from the updated circuit
      (`nargo compile` + `bb write_vk` + `bb write_solidity_verifier`).

### Fixture tooling — `contracts/` (validates circuit ↔ real SMT)
- [x] `SmtFixtureWrapper` drives dl-solarity `SparseMerkleTree` with Poseidon hashers.
- [x] `GenerateSmtFixture` script emits a real `(root, siblings, key, …)` fixture as a
      `Prover.toml` block + JSON; used to pass Check 2.
- [x] `test/fixtures/README.md` — install + run + validate steps.

### Smart contracts — `contracts/` (Foundry, all tests green)
- [x] `ZuitzerlandVerifier` — 4 checks in order (root recency → not banned → not used →
      proof valid), `verify()` + `verifyMultiProof()`, registrar forced into public inputs.
- [x] `ZuitzerlandGovernance` — `Ownable` admin ban/unban; V2 vote-based governance stubbed
      in comments.
- [x] `BaseProviderAdapter` + `RarimoAdapter` + `ZkPassportAdapter` — per-provider
      `registrar` address + `rootValidityWindow` (constructor params, not hardcoded).
- [x] `NoirVerifierWrapper` — adapts the real UltraHonk `verify(...)` to the
      `INoirVerifier.verifyProof(...)` interface.
- [x] Tests (`test/`): happy path, stale root, reused nullifier, banned nullifier,
      session-binding mismatch, ban flow, per-provider windows, registrar-binding
      (positive + negative), wrapper forwarding, governance access control.
- [x] `script/Deploy.s.sol` — deploys + wires the full stack from env vars.
- [x] `ARCHITECTURE.md` — Mermaid diagrams mapped to the E2E flow; reflects the
      single-shared-registry + registrar model.

### Key design decisions (resolved)
- [x] **Single shared ERC-7812 registry** confirmed (`0x781246D2256dc0C1d8357c9dDc1eEe926a9c7812`):
      one global root for all providers; isolation via `getIsolatedKey(registrar, key)`.
- [x] **Per-provider root-validity window** — each adapter sets its own freshness policy
      (e.g. zkPassport 180 days, Rarimo 7 days); enforced non-gameably by binding the
      registrar into the proof.
- [x] **Inactivity / returning members** handled by the root window, not the nullifier.
- [x] **One-time actions** — `usedNullifiers` marked forever is correct once the nullifier
      is scoped per action (future `actionId`).

---

## 🔲 To do

### 1. Confirm real leaf `value` semantics
The fixture uses a placeholder `value`. Confirm what each provider's registrar actually
stores as the leaf value; the client must supply the real one when proving.

### 2. Gather real addresses
- [x] Shared registry: `0x781246D2256dc0C1d8357c9dDc1eEe926a9c7812`
- [ ] Rarimo registrar address
- [ ] zkPassport registrar address
- [ ] Deployed Circuit 1 `Verifier.sol` address (per network)

### 3. Real end-to-end test (on a fork)
Deploy the stack against the real ERC-7812 registry, generate a proof for a leaf that
genuinely exists in the tree, and verify on-chain. Circuit↔SMT and contract logic are each
validated separately; this joins them with the real registry + real registrar value.

### 4. Frontend (separate workstream)
Client that builds `ProofSubmission` and calls `verify` / `verifyMultiProof`, computes
`sessionBinding = hash(wallet, nonce)`, fetches Merkle paths, generates proofs.

### 5. Commit the circuit + fixture work
The latest Circuit 1 changes and the fixture generator are not committed yet.

---

## 🔮 Deferred by design (V2)
- Per-action nullifier (`actionId`) → enables repeated participation across many actions.
- Vote-based governance (quorum of members triggers bans via ZK proof).
- Recursive proof aggregation.
- zkTLS as a third provider (see `docs/ZKTLS_PROVIDER_NOTE.md`).

---

## Critical path
The hard blocker — proving the circuit and the real on-chain SMT agree — is **CLEARED**
(Checks 1 & 2 passed). What's left is integration glue: re-export the verifier (#1), get
real registrar values/addresses (#2, #3), and join everything in a forked end-to-end test
(#4), plus the frontend (#5).
