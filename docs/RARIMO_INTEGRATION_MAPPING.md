# ZuitzPass → Rarimo Integration: Code Mapping & New Design

_Written 2026-06-26. Decision doc — plan before code. No code changed yet._

## Why this doc exists

We set out to fill two STATUS.md to-dos ("real leaf value", "real addresses") and instead
discovered that the architecture we built targets the **wrong layer**. This doc records the
findings, then maps every existing piece to **Keep / Adapt / Replace**, and sketches the new
contract shape.

---

## The findings (verified, not assumed)

1. **The ERC-7812 singleton on Ethereum (`0x781246…`) is deployed but EMPTY.**
   `cast call EvidenceDB.getRoot()` on mainnet returns `0x000…000` (empty-tree root). No
   registrar has ever written to it. It is the *reference deployment of the standard*,
   co-authored by Rarimo + Vitalik + zkPassport — a placeholder for future adoption, not a
   live source of users.

2. **Real registered passports live on the Rarimo chain**, in `StateKeeper` /
   `RegistrationSMT`, with a passport-specific leaf format:
   - `leaf_key   = Poseidon2(passportKey, identityKey)`
   - `leaf_value = Poseidon3(dgCommit, identityReissueCounter, uint64(block.timestamp))`
   This does **not** match our circuit's generic isolated-key leaf.

3. **Rarimo already ships the membership+criteria layer.** Third-party apps are *not* meant
   to hand-roll a membership circuit. The intended on-chain pattern:
   - Inherit **`AQueryProofExecutor`**; call
     `execute(registrationRoot, currentDate, userPayload, zkProof)`.
   - Override `_beforeVerify` / `_buildPublicSignals` / `_afterVerify`.
   - It internally calls **`TD3QueryProofVerifier`** (Groth16, Query circuit, 23 public
     signals). Criteria (nullifier scope, **age/18+**, citizenship, uniqueness, expiry) are
     set as parameters via `PublicSignalsBuilder` — **one circuit, configured at runtime**,
     not one circuit per criterion.
   - Cross-chain: **`RegistrationSMTReplicator`** (1-hour `ROOT_VALIDITY`) mirrors the
     registration root to other chains, so you don't have to run on Rarimo's chain.

**Net:** "prove any requirement" = flags on Rarimo's Query circuit. Our membership circuit is
only meaningful for the generic ERC-7812 path, which has no users yet.

---

## Component-by-component mapping

| Existing piece | Verdict | Why / what it becomes |
|---|---|---|
| `membership_proof/` (Noir circuit) | **Replace (for real users)** | Rarimo's Query circuit + `TD3QueryProofVerifier` already prove membership *and* criteria. Keep ours only as the "generic ERC-7812 standard path" demo. |
| `ZuitzerlandVerifier._verifyOne` check #4 (call Noir verifier) | **Replace** | Becomes `execute(...)` → `TD3QueryProofVerifier`, via `AQueryProofExecutor`. |
| `ZuitzerlandVerifier` checks #2/#3 (banned / used nullifier) | **Keep → move** | Logic is still ours; it moves into the `_beforeVerify` hook. |
| `usedNullifiers` / `bannedNullifiers` mappings | **Keep** | Still our state. Nullifier now comes from Rarimo's public signals (scoped by our `eventId`). |
| `ZuitzerlandVerifier` check #1 (root recency via `getRootTimestamp`) | **Adapt** | Same freshness *idea*, but the root source becomes the `RegistrationSMTReplicator` (`IPoseidonSMT.ROOT_VALIDITY()` / `isRootValid`) instead of the empty ERC-7812 registry. |
| `sessionBinding` + `verifyMultiProof` | **Keep / re-map** | Session binding becomes our `eventId` / `eventData` (`withEventIdAndData`). Multi-proof (Rarimo + zkPassport) is deferred until we have ≥2 live providers. |
| `ZuitzerlandGovernance` (ban/unban, Ownable) | **Keep** | Provider-agnostic. It drives whatever `_beforeVerify` reads. |
| `IProviderAdapter` (registrar + rootValidityWindow) | **Adapt** | "registrar address bound into proof" was a generic-ERC-7812 concept. Under Rarimo the analog is the `registrationRoot` source + `eventId`. Adapter shrinks to "which root source + which window + which Query verifier". |
| `RarimoAdapter` / `ZkPassportAdapter` | **Adapt** | Rarimo adapter points at the real `RegistrationSMTReplicator` + `TD3QueryProofVerifier`. zkPassport stays a stub until its model is confirmed (different — cert-registry, client-side). |
| `NoirVerifierWrapper` | **Replace** | No longer wrapping our Noir verifier; the verifier is Rarimo's `TD3QueryProofVerifier` (Groth16, different interface). |
| `IZuitzerland` interfaces / `ProofSubmission` struct | **Rewrite** | New fields: `registrationRoot`, `currentDate`, `userPayload`, `zkPoints` instead of `(proof, root, nullifier, sessionBinding, registrar)`. |
| Foundry tests + `SmtFixtureWrapper` + `GenerateSmtFixture` | **Keep for the generic path; new tests for Rarimo path** | The dl-solarity fixture validated our circuit ↔ SMT. New path needs tests against `TD3QueryProofVerifier` (likely mock + a fork test). |
| `ARCHITECTURE.md`, `docs/ZKTLS_PROVIDER_NOTE.md`, `STATUS.md` | **Update** | Reflect the two-path reality below. |

---

## New contract architecture (Rarimo path)

```
ZuitzPassExecutor  is  AQueryProofExecutor          (Rarimo base)
  ├─ _beforeVerify(...)      → require !banned[nullifier] && !used[nullifier]   (our state)
  ├─ _buildPublicSignals(...)→ PublicSignalsBuilder:
  │       .withEventIdAndData(ZUITZPASS_EVENT_ID, sessionData)   // our nullifier scope
  │       .withBirthDateBound(18y)                               // criterion: 18+
  │       .withIdentityCounterBound(...)                         // uniqueness
  │       .withExpirationLowerBound(now)                         // valid passport
  └─ _afterVerify(...)       → used[nullifier]=true; emit AccessGranted; grant forum role

  execute(registrationRoot, currentDate, userPayload, zkPoints)
        → checks registrationRoot fresh via RegistrationSMTReplicator (1h window)
        → TD3QueryProofVerifier.verify(23 public signals, Groth16 proof)

ZuitzerlandGovernance (unchanged) ──ban/unban──▶ ZuitzPassExecutor.bannedNullifiers
```

**Two supported paths, explicit:**
- **Path A — Rarimo (real users, recommended):** the diagram above.
- **Path B — generic ERC-7812 (standards demo):** our existing circuit + `ZuitzerlandVerifier`,
  run against a tree we populate ourselves. Kept as-is, clearly labeled "no live users yet".

---

## Open items to confirm before building Path A

1. **`AQueryProofExecutor` exact API** — confirm hook signatures + `PublicSignalsBuilder`
   methods against Rarimo source (`rarimo/passport-contracts`), not just docs.
2. **23 public-signal layout** of the Query circuit (which index = nullifier, eventId,
   citizenship mask, currentDate, registrationRoot, identityCounter).
3. **`RegistrationSMTReplicator` & `TD3QueryProofVerifier` deployed addresses** per target
   chain (not published in docs — find in Rarimo deploy configs / scan.rarimo.com).
4. **Target chain** for ZuitzPass (Rarimo chain directly, or an L2/L1 with the replicator).
5. **zkPassport** — separate effort; confirm whether its (cert-registry, client-side) model
   can be a second provider at all, or is out of scope for v1.

---

## Recommendation

Adopt **Path A (Rarimo `AQueryProofExecutor`)** as the route to gating real humans, keep
**Path B** as the standards-native demo. Next concrete step is item #1–#3 above (pin the real
interfaces), then scaffold `ZuitzPassExecutor`.
