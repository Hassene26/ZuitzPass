# Phase 3 — master-identity, cross-app-unlinkable claims (design spec)

_Written 2026-07-06. Detailed design for the unlinkable identity layer decided in the
architecture discussion. Extends `ARCHITECTURE_UPDATED.md` §4 (which named the direction) with the
concrete key model, the two circuits, and the on-chain changes. This is the target the PoC now
aims at — it turns the pseudonymous Phase-1 system into a strongly-unlinkable one._

---

## 0. Decisions this spec encodes

| Decision | Choice | Consequence |
|---|---|---|
| Identity model | **Master identity** — one secret per person, all claims hang off it | Providers stop being separate subjects; they bind to one `idc` |
| Cross-app unlinkability | **Hard requirement** for the PoC | App-time is a ZK proof + per-app nullifier, not an SLOAD |
| Binding privacy | **Strong** — even the connect step reveals no `provider ↔ idc` link | Needs an anonymity-set / anonymous-credential indirection (§5) |
| Revocation | **Expiry-driven** — no non-membership proof in the circuit | Claims carry `expiresAt`; lapse = revocation; renewal re-proves |
| Canonical registry | **One claims SMT on an L2**, root anchored into ERC-7812 on L1 | Other chains read the anchored root; no registry-per-chain |
| UX | **WalletConnect-for-proofs** — connect providers once, reuse everywhere | Claims are acquired at connect, evaluated at join |

The north-star flow (Alice, "Cannes 2026"): connect World ID, MetaMask, zkPassport, Luma once →
each mints a durable claim bound to her one identity → joining an event whose rule is
`human AND over18 AND balance≥0.02 AND attended-2025` is a single local proof that yields
"eligible + a fresh per-event nullifier", revealing none of her connectors.

---

## 1. Identity & key model

- **Master secret** `s` — a random BN254 field element, generated and kept on Alice's device.
  Never leaves it, never on chain.
- **Identity commitment** `idc = Poseidon2(s, 0)` — reuses the archived circuit's
  `compute_commitment`. This is the "subject" every claim now hangs off (it replaces the Phase-1
  `keccak256(providerId, nullifier)`).
- **Per-app nullifier** `appNullifier = Poseidon(s, appId, contextId)` — deterministic per
  (identity, app, context), unlinkable across apps because `s` is secret. `contextId` = the epoch
  / proposal / event instance (settles "once per X" as a parameter, exactly as Phase 1).

Because claim leaf keys are `Poseidon2(idc, claimType)` and `idc` is a hash of a secret, the whole
claims tree is opaque: scanning it reveals neither who owns a leaf nor which leaves share an owner.

---

## 2. The canonical claims SMT

A single dl-solarity `SparseMerkleTree` (the library ERC-7812 uses; the one the archived circuit +
fixtures already validate against), maintained on the hub L2.

```
leaf key   = Poseidon2(idc, claimType)
leaf value = Poseidon3(issuerId, expiresAt, 0)     // issuerId + expiry, extensible
→ claimsRoot R, timestamped, kept in a bounded root history (like Rarimo's ROOT_VALIDITY)
```

- **Root history** — the gate accepts any `R` seen in the last _T_ (proofs are made against a
  recent snapshot; stale roots are rejected). This is the same freshness pattern as
  `IPoseidonSMT.isRootValid`.
- **ERC-7812 anchoring (cross-chain).** A relayer commits `R` into the Ethereum singleton at
  `getIsolatedKey(ourRegistrar, ZUITZ_CLAIMS_KEY)`. Other chains read the anchored root and verify
  the same proofs — this is what makes it "one logical registry across chains" without a
  registry-per-chain or synchronous cross-chain writes.
  - Note the isolation lives at the **anchor** (our whole tree sits under our registrar key in the
    singleton), NOT per-leaf. This differs from the archived circuit's Model-1 assumption, where
    each user commitment was a leaf directly in the singleton at `Poseidon2(registrar, commitment)`.
    Phase 3 is Model-2: our own tree, anchored. Leaf keys drop the per-leaf registrar term.

---

## 3. Circuit A — eligibility (the generalized membership circuit)

The archived `membership_proof/` lifted from "one inclusion + one nullifier" to "a conjunction of
inclusions + a scoped nullifier". The SMT-reconstruction gadget (`compute_root`, variable-depth,
dl-solarity-matching) is reused verbatim, instantiated N times.

**Public inputs**
- `root` — the claims-SMT root proven against.
- `reqTypes[N]` — the allOf claim types (from the statement). Fixed max N (e.g. 8); unused slots
  set to a sentinel and skipped.
- `anyOfTypes[M]` + `anyOfSelected` — the anyOf set and the index the prover satisfied (empty M = skip).
- `appId`, `contextId` — scope + epoch for the nullifier.
- `nowTs` — current timestamp (the gate checks `nowTs ≈ block.timestamp`).
- `signal` — optional binding (recipient / tx), Semaphore-style.

**Public outputs**
- `nullifier = Poseidon(s, appId, contextId)`.
- `root` echoed.

**Private witness**
- `s`.
- For each allOf slot `i`: `issuerId_i`, `expiresAt_i`, `siblings_i[TREE_DEPTH]`.
- For anyOf: the satisfied type's `issuerId`, `expiresAt`, `siblings`, and `anyOfSelected`.

**Constraints**
1. `idc = Poseidon2(s, 0)`.
2. For each active allOf type `t_i`:
   - `K_i = Poseidon2(idc, t_i)`; `V_i = Poseidon3(issuerId_i, expiresAt_i, 0)`.
   - `leafHash_i = Poseidon3(K_i, V_i, 1)`; assert `compute_root(leafHash_i, siblings_i, K_i) == root`.
   - assert `expiresAt_i == 0 OR expiresAt_i > nowTs` (not expired).
3. anyOf (if `M > 0`): `sel = anyOfTypes[anyOfSelected]`; same inclusion + not-expired checks for
   `sel`'s leaf. (allOf = AND over N; anyOf = prove exactly one of the public set; the gate checks
   `sel ∈ anyOfTypes`.)
4. `nullifier = Poseidon(s, appId, contextId)` → output.
5. Bind `signal` with a dummy `signal * signal` constraint so the proof can't be lifted.

**On-chain gate (per app)** — replaces Phase-1 `check`/`consume` for private statements:
- verify the proof;
- assert `root` is a recent claims root (root-history contract);
- assert `nowTs ≈ block.timestamp` (tolerance);
- assert `reqTypes` / `anyOfTypes` equal the statement's registered definition (a proof for
  statement A cannot satisfy B);
- assert `nullifier` unused for `[statementId][app][contextId]`; mark used;
- check `signal` (e.g. == recipient); then act.

`StatementRegistry` still stores the formula; it just becomes the source of the public
`reqTypes`/`anyOfTypes` the gate feeds the verifier, rather than something it evaluates itself.

---

## 4. Circuit B — private issuance binding (strong)

Getting `Poseidon2(idc, human)` into the tree for a **verified** provider credential with **no**
public `nullifier_provider ↔ idc` link. Strong unlinkability forces an anonymity set: to hide which
of the N verified humans you are, you must prove membership in the set of N without revealing which.
So issuance is two decoupled steps.

**Part A — earn a credential (public; reuses the existing gate).**
- Alice verifies her provider proof (e.g. `WorldIDGate.verify`). This reveals
  `nullifier_provider` and the gate's existing `usedNullifiers` enforces **one credential per
  human** — no new bookkeeping for the nullifier.
- Alice registers a **credential commitment** `C = Poseidon2(s, r)` (fresh blinding `r`) into a
  per-provider **verified-humans tree** (its own SMT / accumulator, root `credRoot_provider`).
- `(nullifier_provider, C)` is public here — that's fine; the link is broken in Part B.

**Part B — redeem into your identity (private; via relayer, later tx).**
- Alice proves in ZK: "I know `(s, r)` opening some leaf `C` in `credRoot_provider` (membership,
  not revealing which) **and** I am writing leaf `Poseidon2(idc, human)` with a valid `expiresAt`."
- The registry writes the claim leaf. Reveals neither `C`, `nullifier_provider`, nor `idc`.
- Anonymity set = every human who did Part A for that provider. Privacy grows with adoption.

Part B is **the same membership primitive as Circuit A** (prove membership in a tree, emit a
scoped output) — so one Noir gadget serves both. An alternative to the on-chain credential tree is
a blind-signature credential (issuer blind-signs `C`), which avoids a tree but adds a signing party;
the tree approach reuses everything we already have.

### 4.1 Circuit B — concrete I/O

The verified-humans tree is an SMT (another `ClaimsSMTRegistry`) with leaves `key = C`, `value = 1`
(a membership marker), `root = credRoot`. Circuit B (`issuance_proof/`):

**Public inputs**
- `credRoot` — provider's verified-humans root (the redeem entrypoint checks it's a recent root).
- `claimType` — the claim being minted (field, `keccak(name) mod p`); binds `leafKey`.
- `leafKey` (output) — `Poseidon2(idc, claimType)`, the opaque claims-SMT key to write.
- `redeemNullifier` (output) — `Poseidon2(r, claimType)`, one-time guard so a credential can't be
  redeemed twice for the same type. Reveals neither `C` nor `idc`.

**Private witness**: `s` (master secret), `r` (credential blinding), `siblings[TREE_DEPTH]` (path of
`C` in `credRoot`).

**Constraints**
1. `C = Poseidon2(s, r)`; `leafHash = Poseidon3(C, 1, 1)`; assert `compute_root(leafHash, siblings, C) == credRoot`
   — membership *without revealing which `C`* (anonymity set = all Part-A humans).
2. `idc = Poseidon2(s, 0)`; assert `leafKey == Poseidon2(idc, claimType)` — binds the write to the
   same identity that owns the credential.
3. assert `redeemNullifier == Poseidon2(r, claimType)`.

**Redeem entrypoint** (the `ClaimsSMTRegistry.redeemer`): verify the proof → `credRoot` fresh →
`(provider, claimType)` permissioned → `redeemNullifier` unused (consume) → `expiresAt <= now +
maxValidity` (policy) → `claimsSmt.addClaimLeaf(leafKey, Poseidon3(issuerId, expiresAt, 0))`.
`issuerId`/`expiresAt` are the entrypoint's (per-provider config + policy), not circuit inputs — the
proof only fixes *which opaque key* gets written and *that it's unforgeable + single-use*.

**Revocation (expiry-driven).** The claim leaf's `expiresAt` is the whole mechanism. A provider
that wants to drop a revoked human rotates its `credRoot_provider` epoch; at **renewal** Alice must
re-prove membership in the *current* credential root, so revoked humans can't renew. Between
renewals, a claim is valid until it lapses — the accepted trade-off for keeping the eligibility
circuit free of a non-membership proof.

---

## 5. Worked example — Cannes 2026

Rule: `human AND over18 AND balance≥0.02 AND attended-cannes-2025`.

| Condition | Provider | Evidence | Claim? |
|---|---|---|---|
| human | World ID | ZK proof → Circuit B binding | durable, `HUMAN`, 6-month expiry |
| over 18 | zkPassport | ZK proof → Circuit B binding | durable, `OVER_18`, expiry |
| attended 2025 | Luma | attestation (signer) or zkTLS → Circuit B binding | durable, `ATTENDED_CANNES_2025` |
| balance ≥ 0.02 | MetaMask | live on-chain read | **not a stored claim** — volatile, checked fresh |

- The three durable facts are acquired **once at connect time**, each bound to Alice's one `idc`
  via Circuit B, and reused at every future event.
- Balance is volatile, so it is **not** minted as a durable claim; the event gate checks it live
  (or accepts a very-short-lived claim). This is the general rule: durable facts → claims;
  volatile facts → live checks.
- Joining is one Circuit-A proof over `{HUMAN, OVER_18, ATTENDED_CANNES_2025}` (+ the live balance
  check), yielding `appNullifier = Poseidon(s, cannes2026, instance)`. The organizer's gate learns
  only "eligible, nullifier X" — not which providers, not her wallet, not a cross-event identifier.

---

## 6. Contract changes from Phase 1

- `ClaimsRegistry` additionally maintains the claims SMT (leaf writes on issue; root history).
  Mapping stays the source of truth; the SMT is the provable index.
- `StatementRegistry` unchanged in storage (allOf/anyOf/consumable), but for **private** statements
  its formula feeds the gate's public inputs rather than being evaluated on-chain. A statement can
  be flagged public (Phase-1 `check`) or private (Circuit-A proof).
- New: a **claims-SMT root-history** contract (freshness), per-provider **verified-humans trees**
  (Part A), a **redeem** entrypoint (Part B verifier → leaf write), and the **eligibility verifier**
  the app gates call. Plus the **ERC-7812 registrar** that anchors `R` to L1.

---

## 7. Gates — two distinct roles, and the indexing rule

"Gate" is overloaded in this doc; they are two unrelated contracts and should be reasoned about
separately.

**Issuer/provider gate** (per *provider* — `WorldIDGate`, `ZuitzPassExecutor`, …). Verifies a
provider's proof and issues a claim; its used-nullifier set is the "one credential per human" guard.
It is per-provider **because each calls a different cryptosystem's verifier** (World ID router =
Semaphore; Rarimo = a Groth16 Query-proof verifier over its SMT; zkPassport = another) — different
proof formats, verifying keys, public-input layouts, often different chains. This per-provider
verification code is irreducible; it cannot be merged into one "checks every proof" routine.

- You *may* front the adapters with a single `Gate` **facade**: one entrypoint holding a
  provider→adapter registry that dispatches to the right verifier and centralizes bookkeeping. That
  gives the "single contract" ergonomics without removing the per-provider adapters behind it.
- The sybil bookkeeping **should** be unified into one registry: a
  `mapping(bytes32 => bool)` keyed `keccak256(providerId, providerNullifier)` (a `mapping`, not an
  array — hash keys are sparse; one cold `SSTORE` per issuance). This consolidates today's per-gate
  `usedNullifiers` without changing behavior.

**App/eligibility gate** (per *app*, but **one shared contract**). Verifies Alice's Circuit-A proof
and consumes her per-app nullifier. "Per app" is only a *scope* — consumption keyed
`[statementId][msg.sender][contextId][nullifier]` — exactly as Phase-1 `StatementRegistry.consume`
already works with one contract. No contract-per-app.

**Indexing rule (hard).** Never key *public* on-chain state by `idc` or anything derived from the
master secret. Two reasons a `[providerId][hash(secret)]` index is wrong:
1. **No sybil resistance** — `secret` is user-chosen, so Alice mints many secrets → many entries.
   Uniqueness must anchor on the value the *provider* guarantees is one-per-human: its nullifier.
2. **Breaks unlinkability** — co-locating `providerId` with `hash(secret)` publicly reconstructs the
   persona graph ("this identity holds World ID + Rarimo + zkPassport"), which is exactly what §4's
   Part-A/Part-B indirection exists to prevent. `idc` appears only *inside* ZK proofs, never as an
   enumerable storage key.

---

## 8. When adding a new provider

Adding provider N is **O(1)** — no new circuit, no changes to the claims tree, the eligibility
circuit/gate, or the redeem entrypoint, and no changes to any app. Almost everything is written
once and generic.

**Reused for every provider (zero per-provider code):** the claims tree (`ClaimsSMTRegistry`);
Circuit A + its verifier + `EligibilityGate`; **Circuit B + its verifier** (generic — `claimType`
is a public input, so one issuance circuit covers all providers/types); `RedeemIssuer`;
`RootedSMTRegistry`.

**Add for provider N:**

| # | Add | Cost |
|---|---|---|
| 1 | A **provider adapter** verifying *that provider's* proof (World ID router / Rarimo / zkPassport …) | The one irreducible piece — same as Phase 1; different cryptosystems can't share verification code |
| 2 | A **`VerifiedHumansTree` instance** (`new VerifiedHumansTree(...)`), adapter set as its `writer` | no new code |
| 3 | A **Part-A hook** in the adapter: on success, `verifiedHumansTree.insertCredential(C)` (Alice supplies `C = Poseidon2(s, r)`) | small additive hook, like the Phase-1 issuance hook |
| 4 | `RedeemIssuer.registerProvider(providerId, credTree, claimType, issuerId)` | one governance tx |
| 5 | Register the claim type, if new | one governance tx |

**Overhead:** one adapter (unavoidable — you need it to talk to the provider) + a tree *deploy* (no
code) + a small hook + two config txs. The extra unlinkable machinery (credential commitment +
redeem) is paid **once**, in the generic Circuit B + `RedeemIssuer`, not per provider.

A provider that issues several claim types (a passport → `HUMAN` *and* `OVER_18`) registers under
multiple `providerId`s pointing at the same tree — still config, no code, and it composes because
`redeem_nullifier = Poseidon2(r, claimType)` differs per type (one credential redeems once per type).

---

## 9. Open questions / risks

- **Anonymity-set size.** Privacy is only as strong as the number of humans who did Part A for a
  provider. Small sets → weak hiding. Mitigation: shared trees per provider, not per app.
- **Balance volatility.** Confirmed live-check, not a claim — but "live" means the gate reads
  `balanceOf` at join, which links the wallet at that moment. Acceptable for access; note it.
- **Client-side proving UX.** Circuit A runs on Alice's device (fetch paths from an indexer, prove
  in ~seconds). Real component the PoC doesn't have yet.
- **Cross-chain root latency.** An app on chain B verifies against the last anchored `R`; issuance
  on the hub is only visible after the next anchor. Fine for durable claims, bad for anything fresh.
- **Luma trust.** Attestation (they sign) vs zkTLS (adversarial) — deferred research.
- **Audit surface.** Two circuits + the SMT gadget + the anchor. One audit, non-trivial.

---

## 10. Build order

1. ✅ **Circuit A (eligibility)** — `eligibility_proof/` (`nargo test` + `nargo execute` green).
   Multi-leaf fixture generator (`GenerateEligibilityFixture.s.sol`) + Solidity "Check 2"
   (`test/EligibilityFixture.t.sol`) confirm `compute_root` reproduces the real dl-solarity root
   for a genuine conjunction.
2. ✅ **On-chain spine + gate** — `src/phase3/ClaimsSMTRegistry.sol` (SMT + root history) and
   `src/phase3/EligibilityGate.sol` (verify → root freshness → time → app-scope → claim-types ==
   statement → consume nullifier), against `IEligibilityVerifier`. Tested with a mock verifier.
   Claim types use the canonical `keccak256(name) mod p` form (decision #1).
3. ✅ **Eligibility verifier deployed + wired** — UltraHonk (keccak flavor) exported and deployed
   on World Chain Sepolia; `EligibilityGate` points at it. Fixture uses canonical
   `keccak(name) mod p` claim types. ⏳ Remaining: the live proof → gate replay (needs the SMT
   seeded + a gate-consistent fixture: `app_id = appScope(app, statementId)`, `now_ts ≈ block.ts`).
4. ✅ **Circuit B (issuance binding) + on-chain half** — `issuance_proof/` (nargo green);
   `RootedSMTRegistry` (shared base), `VerifiedHumansTree`, `RedeemIssuer` (verify → provider
   permission → cred-root freshness → expiry policy → consume redeem-nullifier → `addClaimLeaf`),
   tested with a mock verifier. ⏳ Remaining: deploy the Circuit-B verifier + `VerifiedHumansTree` +
   `RedeemIssuer`, wire `RedeemIssuer` as the `ClaimsSMTRegistry.redeemer`, and a Part-A insertion
   path (provider gate → `insertCredential`).
5. **Full live demo** — insert credential → Circuit B redeem → claim leaf → Circuit A eligibility →
   `EligibilityGate.consume`, unlinkable, end to end.
6. ERC-7812 anchor + a second-chain read demo.
