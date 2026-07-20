# Private email evidence — what we built, and how to use it

> New to the project? Read [`READ_ME_FIRST.md`](../READ_ME_FIRST.md) first — it frames where this
> doc sits (this is *the how*: the first concrete feature, end to end).

_Written 2026-07-13. A standalone walkthrough of the email-evidence feature: the problem, the
design decision, the pieces we actually shipped, and a concrete end-to-end usage example (with
the real addresses proven live on World Chain Sepolia). Companion to the design note
[`PRIVATE_PROVABILITY_FRAMEWORK.md`](PRIVATE_PROVABILITY_FRAMEWORK.md) — that one is the theory;
this one is "here is the thing, here is how you run it."_

---

## 1. The problem we set out to solve

ZuitzPass gates access on **statements** — conjunctions like _"a unique human AND holds a ticket
to Cannes 2026."_ Personhood we already had (World ID, passports). The missing half was
**attribute** facts that live in Web2: _did this person actually get a ticket?_ That truth sits in
a Luma/Eventbrite confirmation email or a login session on a ticketing site.

We wanted to prove such a fact with four properties held **at once**:

1. **Private** — our backend/platform must never see the raw email or login data.
2. **Bound** — the proof must cryptographically commit to the user's identity, so a valid proof
   can't be lifted and replayed under someone else's account.
3. **On-chain verifiable** — ideally checked inside an EVM contract with **no trusted third
   party** in the loop (no "our server says so").
4. **Specific** — it must assert _which_ event (Cannes 2026, not Rome 2023), matched over data
   the source actually signed.

The earlier spike (`demo-app/backend/dkim.js`) verified a Luma email's DKIM signature **on the
backend** — real cryptography, but it violated (1) (the server saw the email) and (3) (you had to
trust that server). This feature closes that gap.

---

## 2. The key decision: sign-at-source beats zkTLS

The brief said "ideally via zkTLS." We pushed back, and this is the crux of the whole design:

- **TLS has no non-repudiation.** A ticketing website never signs the data it shows you, so every
  zkTLS scheme (notary / MPC / proxy) has to synthesize a *witness* to vouch for the transcript.
  That witness is a permanent trust assumption — no amount of ZK removes it.
- **A confirmation email is already signed at the source.** DKIM is an RSA signature by `lu.ma`
  over the email's headers, with the public key published in DNS. Nothing needs to witness it. The
  entire check can run inside a zero-knowledge circuit and be verified by an EVM contract.

So for the anchor case — event attendance — the trustless path is **zk-email**, not zkTLS. (zkTLS
stays the right tool only for facts that live *solely* behind a login with no signed artifact,
e.g. a bank balance. That's a separate, later track.)

---

## 3. What we actually built

Five new pieces, and — crucially — **everything downstream was reused unchanged**. The existing
Phase-3 unlinkable machinery (the claims tree, the redeem flow, the eligibility gate, both
existing circuits) did not need a single line changed.

### 3.1 Circuit C — the email evidence proof (`email_proof/`)

A Noir circuit built on the audited [`zkemail.nr`](https://github.com/zkemail/zkemail.nr) library.
It runs **on the user's own machine** and proves, in zero knowledge:

- the email header carries a valid **DKIM signature** (RSA-2048/SHA-256) — forged/edited emails
  fail;
- the **signed `subject`** contains a specific event token (e.g. `evt_cannes2026`) — this is the
  "which event" check, over bytes the sender actually signed;
- a per-email **nullifier** = `pedersen(signature)` — one email can mint one credential, ever;
- the proof is **bound** to the user's credential commitment `C = Poseidon2(secret, r)`.

It outputs 5 public values and **nothing else** — the email itself never leaves the device. See
[`email_proof/src/main.nr`](../email_proof/src/main.nr).

> **The binding is the important part.** `C` is a public input the circuit is *forced* to compute
> from the user's secret. If someone intercepts the proof, they can't re-bind it to their own
> identity without re-proving — which requires the email *and* the secret. That's what makes the
> resulting claim non-transferable.

### 3.2 `EmailEvidenceVerifier.sol` — the on-chain adapter

The trustless replacement for the backend DKIM check. Anyone (a relayer, the user, doesn't matter
— the proof binds `C`) calls `submitEvidence(sourceId, proof, pub)`, and the contract:

1. verifies the Circuit-C proof against the on-chain verifier;
2. checks the signing key is an allowed key for the source's domain (via `DKIMKeyRegistry`);
3. checks the event token matches the registered event (the "which event" pin);
4. consumes the email nullifier (one email = one credential);
5. inserts `C` into that event's anonymity-set tree (`VerifiedHumansTree`).

No attestor, no signer, no backend trust. See
[`contracts/src/phase3/EmailEvidenceVerifier.sol`](../contracts/src/phase3/EmailEvidenceVerifier.sol).

### 3.3 `DKIMKeyRegistry.sol` — the one honest trust residue

Somebody has to assert "this is lu.ma's real DNS key." That's this contract: a
governance-managed allowlist of DKIM keys per domain, with key *retirement* (so a rotated/
compromised key can be cut off while historical emails stay provable). It's the only trust
assumption besides Luma's own key custody and the circuit's soundness. See
[`contracts/src/phase3/DKIMKeyRegistry.sol`](../contracts/src/phase3/DKIMKeyRegistry.sol).

### 3.4 Deploy + fixture tooling

- [`contracts/script/DeployEmailVerifier.s.sol`](../contracts/script/DeployEmailVerifier.s.sol) —
  deploys the Circuit-C UltraHonk verifier.
- [`contracts/script/DeployEmailEvidence.s.sol`](../contracts/script/DeployEmailEvidence.s.sol) —
  deploys the registry + evidence adapter + a per-event tree, registers the key/source, and wires
  the event as a provider on the existing `RedeemIssuer`.
- [`demo-app/backend/make-test-eml.mjs`](../demo-app/backend/make-test-eml.mjs) — generates a
  self-signed Luma-style `.eml` so you can run the whole thing with no real inbox.
- [`demo-app/backend/make-email-proof-inputs.mjs`](../demo-app/backend/make-email-proof-inputs.mjs)
  — turns an `.eml` into the circuit's `Prover.toml` (runs locally; the email stays on the device).

### 3.5 Tests

[`contracts/test/EmailEvidenceVerifier.t.sol`](../contracts/test/EmailEvidenceVerifier.t.sol) —
11 tests (replay, retired key, wrong event, disabled source, permissionless submit). Full suite:
115 passing.

---

## 4. How it fits the existing system (the whole pipeline)

The email feature is only the first two boxes. Everything after "credential" is the
**pre-existing, unchanged** Phase-3 flow — that's the payoff of the framework's "no new
statements-layer machinery" rule.

```
  Alice's device                         on-chain (World Chain Sepolia)
  ──────────────                         ─────────────────────────────
  .eml  ──►  Circuit C  ──────────►  EmailEvidenceVerifier         │ NEW
            (zk-email,               · verify proof                │
             binds C)                · check DKIM key (registry)   │
                                     · check event token          │
                                     · consume email nullifier    │
                                     · insertCredential(C)  ───────┼─► VerifiedHumansTree
                                                                   │       (per event)
  ────────────────────────────────────────────────────────────────
            Circuit B  ──────────►  RedeemIssuer.redeem            │ EXISTING,
            (existing)              · verify · consume redeem-null │ UNCHANGED
                                    · addClaimLeaf ────────────────┼─► ClaimsSMTRegistry
                                      Poseidon2(idc, EVENT_...)    │   (opaque claim)
  ────────────────────────────────────────────────────────────────
            Circuit A  ──────────►  EligibilityGate.consume        │ EXISTING,
            (existing)              · verify · check root/time     │ UNCHANGED
                                    · match statement claim types  │
                                    · burn per-app nullifier       │
                                                                   ▼
                                            App learns: "eligible + nullifier X"
                                            — never the email, the wallet, or the identity
```

**Why the two-step (Part A insert, then Part B redeem)?** Part A publicly reveals `(email
nullifier, C)` — Luma could link *an email* to `C`. The separate redeem transaction (different
time, relayer-friendly) breaks the link between `C` and the final claim leaf, hiding the user
inside the anonymity set of everyone who redeemed a ticket for that event. The identity `idc`
never appears on-chain.

---

## 5. What "trustless" costs here (honest trust boundary)

| Who/what you must trust | Why | Mitigation |
|---|---|---|
| Luma's DKIM key custody | if Luma's signing key leaks, false ticket emails could be forged | key retirement + acceptance deadlines in `DKIMKeyRegistry` |
| `DKIMKeyRegistry` governance | someone asserts what lu.ma's key *is* | multisig; multi-party key observation before registering; later, DNSSEC proofs |
| Circuit + verifier soundness | a broken circuit could prove false statements | `zkemail.nr` is audited (Consensys Diligence + Veridise); our composition is ~150 lines |

What you **do not** trust: our backend (never sees the email), any attestor/signer (there is
none), any zkTLS notary/witness (not used). Compared to the old DKIM spike, this removes the
backend from the trust set entirely.

**Sybil note (always):** an email proves an *attribute*, not personhood — one human can hold many
Luma accounts. Statements must always compose it with a personhood claim, e.g.
`allOf: [UNIQUE_HUMAN, EVENT_ATTENDED_CANNES2026]`, never gate on the ticket alone.

---

## 6. Use example — "Cannes 2026 ticket-holders lounge"

Bob runs a privacy-preserving lounge for verified humans who hold a Cannes-2026 Luma ticket, and
must not be able to track who showed up. Here's how each party uses what we shipped. This is the
**exact flow we proved live** on World Chain Sepolia (chainId 4801).

### 6.0 Deployed pieces (from the live run)

| Contract | Address |
|---|---|
| DKIMKeyRegistry | `0x7E132c95bb1ee268271b6BE44271808072Bd7F66` |
| EmailEvidenceVerifier | `0xAFa8818CF321af939a654B22E526ac9551c7c058` |
| VerifiedHumansTree (luma:evt_cannes2026) | `0xE857825D3CF47084971728FFA6ed65d10552aCbA` |
| EmailVerifier (Circuit C) | `0x798c56E73445918D72e1421737C19A45fF868Aea` |
| RedeemIssuer (existing) | `0xEa23848413b452F8be43B51D4eB1437C0C62ae45` |
| ClaimsSMTRegistry (existing) | `0xED95aCC61243503144D3C17AC130f3051CE99283` |
| EligibilityGate (existing) | `0x8413A17eE390a84357ef175c32BC77283D6f6af7` |
| StatementRegistry (existing) | `0x9518201B65b3b9a26a80Cf7605952620C9498001` |

Key identifiers: claim type `EVENT_ATTENDED_CANNES2026` (= `keccak(name) mod p`) =
`0x173a01fa…a5c4`; source id (`keccak("luma:evt_cannes2026")`) =
`0x2e5733258f69acb9e6228c9b70fc90f08d8551343cce9ca0cb28d971375401ff`.

### 6.1 One-time setup (governance / event organizer)

Deploy the email-evidence stack for the event and register the statement. Done once per event:

```bash
# (a) deploy the Circuit-C verifier exported by bb
forge script script/DeployEmailVerifier.s.sol --rpc-url $RPC --broadcast --account dev

# (b) deploy registry + adapter + per-event tree, wire the RedeemIssuer provider
EMAIL_VERIFIER=0x798c… DKIM_KEY_HASH0=0x13ea… DKIM_KEY_HASH1=0x0a2c… EVENT_ID_HASH=0x1614… \
  forge script script/DeployEmailEvidence.s.sol --rpc-url $RPC --broadcast --account dev

# (c) register the access rule (compose ticket WITH personhood)
STMT=$(cast keccak "CANNES_LOUNGE_2026")
cast send $STATEMENTS "registerStatement(bytes32,(bytes32[],bytes32[],bool,string))" $STMT \
  "([0x28c2…UNIQUE_HUMAN,0x173a…EVENT_ATTENDED_CANNES2026],[],true,\"ipfs://…\")" \
  --rpc-url $RPC --account dev
```

`DKIM_KEY_HASH0/1` and `EVENT_ID_HASH` come from running the circuit once (§6.2) — they're
deterministic public outputs.

### 6.2 Alice proves her ticket (on her own machine)

```bash
# turn her Luma .eml into the circuit witness — the email never leaves her device
node demo-app/backend/make-email-proof-inputs.mjs her-ticket.eml evt_cannes2026 <secret> <r>

# prove locally (WSL; email_proof needs nargo 1.0.0-beta.5 + matching bb — see the Nargo.toml note)
cd email_proof && nargo execute && \
  bb prove --scheme ultra_honk --oracle_hash keccak -b target/email_proof.json \
           -w target/email_proof.gz -o target
```

`nargo execute` prints the 5 public outputs (key hashes, event id, email nullifier, `C`).

### 6.3 Submit evidence → credential lands (Part A)

```bash
cast send $EVIDENCE "submitEvidence(bytes32,bytes,bytes32[])" \
  $SOURCE_ID 0x<proof> "[<kh0>,<kh1>,<event_id>,<email_nullifier>,<C>]" \
  --rpc-url $RPC --account anyone   # permissionless — a relayer works
```

Her blinded credential `C` is now in the event's `VerifiedHumansTree`. The chain learned only that
*some* Cannes ticket-holder registered a credential.

### 6.4 Redeem into her identity (Part B — existing flow)

She proves Circuit B (she owns *some* `C` in the tree, without revealing which) and redeems it
into an opaque claim on her master identity:

```bash
cd issuance_proof && nargo execute --prover-name Prover-email && bb prove …
cast send $REDEEM "redeem(bytes32,uint64,bytes,bytes32[])" \
  $SOURCE_ID <expiry> 0x<proof> "[<cred_root>,<claim_type>,<leaf_key>,<redeem_nullifier>]" \
  --rpc-url $RPC --account anyone
```

`ClaimsSMTRegistry` now holds `Poseidon2(idc, EVENT_ATTENDED_CANNES2026)` — an opaque leaf. Nothing
links it to her email or her wallet.

### 6.5 Enter the lounge (Circuit A — existing flow)

She proves Circuit A: _"under the current claims root I hold valid claims of the types this
statement requires, and here is my per-app nullifier."_ Bob's app calls
`EligibilityGate.consume(...)`.

```bash
cd eligibility_proof && nargo execute --prover-name Prover-email && bb prove …
cast send $GATE "consume(bytes32,uint256,uint256,bytes,bytes32[])" \
  $STMT 1 0 0x<proof> "[<pub…>]" --rpc-url $RPC --account alice
```

**Result:** Bob's lounge learns only _"a unique human holding a valid Cannes ticket entered,
nullifier X."_ Not her identity, not her email, not her wallet — and a different app would see a
different nullifier for the same Alice. Luma never saw Bob's contract; Bob's contract never saw
Alice's email. That's the whole thesis in one flow.

---

## 6b. Two paths in the demo app (2026-07-13)

The demo's Step 5 now offers **both** paths, so the trade-off is visible side by side:

| | Fast lane (server-side DKIM) | Trustless path (real Circuit C) |
|---|---|---|
| Where the email is checked | backend (`evidence.js`) | the user's machine (Circuit C) |
| Backend sees the email? | **yes** | **no** |
| Binds the user's identity? | no | **yes** (`C`) |
| Single-use on-chain? | no | **yes** (`email_nullifier`) |
| Result | a session fact | an **on-chain** unlinkable claim |
| Sources | ruleset (Luma/ETH/tax samples) | deployed sources only (Cannes today) |

The fast lane is for quickly demoing the *aggregation UX* ("throw a batch, see the statement");
the trustless path is the real thing for the one deployed source. Backend wiring:
`/api/evidence/email-params` (proving params — no email), `/api/evidence/submit-tx` (Part A
calldata from the local proof), `/api/evidence/redeem-email-tx` (backend proves Circuit B — no
email — → redeem calldata), and `/api/evidence/validate` (reads the **on-chain** claim). The
`.eml` reaches the backend in neither of the trustless-path calls.

> **Note (latent bug fixed 2026-07-13):** the demo's `getProof` ABI had its return-tuple fields
> mis-ordered vs dl-solarity's `Proof` struct, so `proof.existence` decoded the `value` field and
> read `true` for *absent* keys. Harmless for the live redeem (which used only `root`/`siblings`)
> but it made on-chain membership checks meaningless. Fixed in `config.js`; see the spun-off audit.

## 7. What you can do with this today

- **Gate anything on a signed-email fact, privately.** Any email a trustworthy sender signs with
  DKIM works the same way: airline boarding confirmations, hotel bookings, receipts, employment
  offers, "thanks for attending" follow-ups. Onboarding a new one is: pick the token in the signed
  headers → deploy a source (one script) → register a statement. No new circuit.
- **Compose it with personhood and other claims** in one statement (`allOf`), evaluated either
  pseudonymously (Phase-1 `check`) or unlinkably (Circuit A). The statements layer doesn't care
  where a claim came from.
- **Run the whole demo with no real inbox** via `make-test-eml.mjs` (self-signed key, auto-loaded).

---

## 8. Known gaps / caveats (from the live run)

1. **Claim renewal.** Once a credential's redeem nullifier is consumed, an *expired* claim can't
   currently be refreshed — we hit this when the demo's `UNIQUE_HUMAN` claim lapsed. A renewal path
   in `RedeemIssuer` is being built (spun-off task). Until then, claims are valid until expiry, then
   need a fresh credential.
2. **Root freshness.** `RootedSMTRegistry.isRootValid` expires even the current root after
   `rootValidity`; we widened the claims-tree window to 7 days as a stopgap. Proper fix: treat the
   latest root as always valid (like Rarimo).
3. **Timing coupling.** A Circuit-A proof carries `now_ts` and must be consumed within the gate's
   1-hour tolerance — prove immediately before submitting. Inherent to replay protection.
4. **Toolchain split.** `email_proof/` builds only on nargo `1.0.0-beta.5` (zkemail.nr v2.0.0's
   pinned toolchain); the other two circuits stay on the repo's newer toolchain. Poseidon outputs
   were verified bit-identical across both, so the pieces interoperate.
5. **Real Luma template.** We proved it against a self-signed fixture with the token in the
   subject. A real Luma email may carry the event id in a different signed header or the body — that's
   a per-source analysis step (possibly needing body matching), not a redesign.
6. **Anonymity-set size.** Privacy scales with how many people redeemed for that event; a size-1
   set hides nothing. Real events have hundreds.
