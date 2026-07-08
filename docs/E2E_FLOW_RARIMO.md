# ZuitzPass — End-to-End Flow (Real / Rarimo path)

_Written 2026-07-03. This replaces the earlier idealized "empty-singleton" flow. It describes
the **only path that gates real users**: Rarimo's live passport registry + its
`AQueryProofExecutor` integration layer. See
[`RARIMO_INTEGRATION_MAPPING.md`](RARIMO_INTEGRATION_MAPPING.md) for the code mapping and
[`rarimo-zkpassport-registry-facts`] for the verified facts behind it._

> **Legend.** 🟢 = already live in the Rarimo ecosystem (we consume, don't build).
> 🔵 = ZuitzPass work (this repo). 🟡 = needs confirmation against Rarimo source before build.

> **The core shift from the old flow:** we do **not** run a registry, a tree server, or our own
> membership circuit. Passport identities already live in Rarimo's `RegistrationSMT` on the
> Rarimo chain, and Rarimo's **Query circuit** already proves membership *plus* criteria. Our
> job is a single contract (`ZuitzPassExecutor`) that plugs into Rarimo's verifier and adds
> ZuitzPass policy (nullifier/ban/governance/criteria).

---

## Phase 1 — One-time setup

🟢 **Rarimo's registry is already deployed and operating** on the Rarimo chain — we set up
nothing here:
- `StateKeeper` (`0x61aa5b68…`) holds the `RegistrationSMT` (`0x479F8450…`) of registered
  identities. Live, populated with real users today.

🔵 **What ZuitzPass deploys:**
1. `ZuitzPassExecutor is AQueryProofExecutor` — configured with: the `TD3QueryProofVerifier`
   address, the registration-root source, a fixed **`eventId`** (the ZuitzPass scope), and the
   **criteria policy** (e.g. 18+, not-expired, uniqueness).
2. `ZuitzerlandGovernance` (unchanged) — drives the ban list read in `_beforeVerify`.

🟡 **Cross-chain root:** ZuitzPass must read a *fresh registration root* on its target chain. If
ZuitzPass does not run on the Rarimo chain itself, a **`RegistrationSMTReplicator`** (1-hour
`ROOT_VALIDITY`) mirrors the Rarimo registration root onto the target chain. **To confirm:** the
replicator's deployed address per chain, and which chain ZuitzPass targets.

---

## Phase 2 — User registers a passport with Rarimo (once, reusable everywhere)

🟢 This happens in **Rarimo's app (RariMe)**, independent of ZuitzPass, and is reused across
*every* Rarimo-integrated app — the user does it once, not per-app:

1. User scans their passport via NFC; the app verifies the government signature locally
   (full mode) or delegates the signature check to a Rarimo verifier (light mode). Raw passport
   data never leaves the device.
2. The app derives an identity keypair `sk_i, PK_i` and a personal-data **blinder** = `Hash(sk_i)`.
3. It computes the passport commitment **`dgCommit = Hash(DG1 ‖ blinder)`** (`DG1` = passport data group).
4. Rarimo registers it on-chain (`Registration2` → `StateKeeper.addBond`), writing into
   `RegistrationSMT`:
   - **leaf key** = `Poseidon2(passportKey, identityKey)`
   - **leaf value** = `Poseidon3(dgCommit, identityReissueCounter, uint64(block.timestamp))`
5. The SMT updates → a new **registration root** (kept in history, timestamped).

> The user's durable secret is **`sk_i`** (identity key). Lose it → lose access, exactly like
> the old flow's `secret`. The difference: it's a Rarimo identity, not a ZuitzPass-specific one.

---

## Phase 3 — User proves membership for ZuitzPass (client-side Query proof)

🔵 ZuitzPass app requests a proof; 🟢 RariMe / `@rarimo/zk-passport` generates it:

1. ZuitzPass asks for a **Query proof** with a specific query:
   `eventId = ZUITZPASS`, criteria = `{ age ≥ 18, passport not expired, uniqueness }`.
2. The client generates the proof against the **current registration root**:
   - **Private inputs:** `sk_i`, passport data, Merkle path in `RegistrationSMT`.
   - **Public signals** (the Query circuit's output, 🟡 *23 items — exact layout to confirm*):
     a **nullifier** scoped to `eventId`, the criteria results (citizenship / age / expiry),
     `currentDate`, the `registrationRoot`, and an `identityCounter` (for uniqueness).
3. The **nullifier is derived from the identity and `eventId`**, so it is *stable per
   (person, ZuitzPass)* and independent of the root → one human, one ZuitzPass account.
4. Output: a compact **Groth16 proof** (`zkPoints`) + the public-signals bundle.

> We do **not** write or run this circuit. It's Rarimo's Query circuit; "prove any criteria"
> is expressed as **flags in the query**, not as a new circuit.

---

## Phase 4 — ZuitzPass verifies on-chain

🔵 The client calls **one** function on our contract:

```solidity
zuitzPassExecutor.execute(registrationRoot, currentDate, userPayload, zkPoints);
```

```mermaid
sequenceDiagram
    autonumber
    participant Cli as User's device (RariMe/SDK)
    participant Z as ZuitzPassExecutor (ours)
    participant Root as RegistrationSMTReplicator
    participant TD3 as TD3QueryProofVerifier (Rarimo)

    Cli->>Z: execute(registrationRoot, currentDate, userPayload, zkPoints)
    Z->>Root: isRootValid(registrationRoot)?  (≤ 1h)
    Root-->>Z: fresh? else revert (stale root)
    Z->>Z: _beforeVerify(): nullifier banned? used? -> revert
    Z->>Z: _buildPublicSignals(): assert eventId=ZUITZPASS,<br/>age≥18, not expired, uniqueness (PublicSignalsBuilder)
    Z->>TD3: verify(publicSignals[23], zkPoints)  (Groth16)
    TD3-->>Z: true  (else revert)
    Z->>Z: _afterVerify(): usedNullifiers[n]=true; grant access; emit
    Z-->>Cli: AccessGranted
```

Step-by-step (🟢 base contract vs 🔵 our hooks):
1. 🟢 Base contract checks `registrationRoot` is **fresh** via the replicator (`isRootValid`,
   ≤ 1 h) — reverts if stale. *(This is the real analog of the old `getRootTimestamp` check.)*
2. 🔵 `_beforeVerify` — nullifier **not banned** and **not already used**, else revert.
3. 🔵 `_buildPublicSignals` — pin the query with `PublicSignalsBuilder`:
   `withEventIdAndData(ZUITZPASS, …)`, birth-date bound (**≥ 18**), expiration lower bound
   (`currentDate`), identity-counter bound (**uniqueness**). This is what forces the criteria.
4. 🟢 `TD3QueryProofVerifier.verify(...)` runs the Groth16 math.
5. 🔵 `_afterVerify` — mark nullifier used, grant forum/governance access, emit event.

**Result:** ZuitzPass learns *only* that the user satisfies the criteria and holds a stable,
anonymous nullifier — never their identity, passport, or leaf position.

🟡 **To confirm before build:** exact `AQueryProofExecutor` hook signatures + `PublicSignalsBuilder`
API against `rarimo/passport-contracts`, and the 23-signal index layout.

---

## Phase 5 — Returning user / root refresh

The registration root advances as new users register, and the replicated root refreshes each
hour. The user's registration (leaf) is unchanged.

- The client simply regenerates the Query proof against the **current** root and calls
  `execute` again. The **nullifier is identical** (scoped to `eventId`, root-independent), so
  the used/banned checks behave exactly as before.
- **One-time actions** (vote once, claim once): scope the nullifier per **`(eventId, actionId)`**
  — in Rarimo terms, per-action `eventData` — so a user can act *once per action* while still
  being one identity. No contract redesign; it's a query parameter.

---

## Dependencies & open questions (honest)

1. 🟡 **Target chain + replicator address** — where ZuitzPass runs, and the deployed
   `RegistrationSMTReplicator` / `TD3QueryProofVerifier` addresses there.
2. 🟡 **Query circuit public-signal layout** (the 23 items) and the `AQueryProofExecutor` /
   `PublicSignalsBuilder` API — confirm from Rarimo source, not docs.
3. 🟡 **Criteria availability** — that Rarimo's Query circuit exposes exactly the predicates we
   want (age, expiry, uniqueness; citizenship if needed).
4. **zkPassport as a 2nd provider** — separate model (cert-registry, client-side); out of scope
   for this flow until confirmed it can normalize to the same nullifier + criteria shape.
5. **Trust footprint** — this path ties ZuitzPass to Rarimo's chain, its replicator, and (in
   light mode) its signature verifier. That is the price of gating real users today.
