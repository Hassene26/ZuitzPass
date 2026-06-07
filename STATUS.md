# Zuitzerland — Project Status

_Last updated: 2026-06-07_

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
- [x] Membership proof circuit (`src/main.nr`): commitment, SMT inclusion (depth 20,
      Poseidon), nullifier derivation, session-binding pass-through.
- [x] 3 passing tests (happy path, mixed-index path, bad-root rejection).
- [x] Compiles; UltraHonk Solidity verifier exported via BB (`target/Verifier.sol`).
- [x] Docs: `HANDOFF.md`, `CIRCUIT1_ISOLATED_KEY_NOTE.md`.
- [!] **Pending change** — does not yet implement ERC-7812 isolated keys or expose
      `registrar` as the 4th public input (see "To do" #1). Until then it produces a
      3-input proof that will NOT verify against the real registry.

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

### 1. Circuit 1 — isolated-key change (CRITICAL, blocks real E2E)
Contracts expect 4 public inputs; the circuit still produces 3 and uses
`leaf_key = Poseidon(secret)`. Update the circuit to:
- derive `leaf_key = getIsolatedKey(registrar, Poseidon(secret))`
- expose `registrar` as the 4th public input
- update tests + re-export the verifier
See `membership_proof/CIRCUIT1_ISOLATED_KEY_NOTE.md`.

### 2. Confirm the real `getIsolatedKey` scheme
Read the exact hashing (hash fn, address encoding, argument order) off the deployed
registry / Rarimo's implementation and match it bit-for-bit in the circuit.

### 3. Gather real addresses
- [x] Shared registry: `0x781246D2256dc0C1d8357c9dDc1eEe926a9c7812`
- [ ] Rarimo registrar address
- [ ] zkPassport registrar address
- [ ] Deployed Circuit 1 `Verifier.sol` address (per network)

### 4. Real end-to-end test
Generate a real proof from the updated circuit and run it through the deployed stack —
ideally a forked-network test against the real ERC-7812 registry — to prove circuit and
contracts agree on encoding.

### 5. Frontend (separate workstream)
Client that builds `ProofSubmission` and calls `verify` / `verifyMultiProof`, computes
`sessionBinding = hash(wallet, nonce)`, fetches Merkle paths, generates proofs.

---

## 🔮 Deferred by design (V2)
- Per-action nullifier (`actionId`) → enables repeated participation across many actions.
- Vote-based governance (quorum of members triggers bans via ZK proof).
- Recursive proof aggregation.

---

## Critical path
**#1 → #2 → #4.** Updating Circuit 1 for isolated keys is the single highest-value next
step: "real proofs verifying on-chain" depends on it, and it is the one place the circuit
and contracts must move together.
