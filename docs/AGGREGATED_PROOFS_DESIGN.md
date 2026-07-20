# Aggregated proofs + "upload any signed document" — design

> New to the project? Read [`READ_ME_FIRST.md`](../READ_ME_FIRST.md) first — it frames where this
> doc sits (this is *the composition story*: persistence vs one-shot, and the gate ladder).

_Written 2026-07-13. Design note, no code changed yet. The vision: a user assembles an arbitrary
bundle of facts — "I'm a human AND attended Cannes 2026 AND studied in Switzerland AND paid taxes
in 2025" — by **uploading the documents that prove them** (`.eml`, signed PDF, eID credential, …),
proving each **privately in the browser** (bb.js/NoirJS), and having it all compose smoothly. Builds directly on
the shipped email-evidence feature ([`EMAIL_EVIDENCE_WALKTHROUGH.md`](EMAIL_EVIDENCE_WALKTHROUGH.md))
and the framework ([`PRIVATE_PROVABILITY_FRAMEWORK.md`](PRIVATE_PROVABILITY_FRAMEWORK.md))._

**Decisions locked for this doc (2026-07-13):** design-doc first (this); proving moves to the
**browser** (bb.js/NoirJS); **unsigned documents are rejected with a clear explanation**; the
*next* document class (JWT/SD-JWT vs PDF) is deliberately left open — the design must make adding
either a plug-in, not a rewrite.

---

## 0. The reframe: aggregation is (mostly) already built

The single most important thing to say before designing anything: **ZuitzPass already aggregates
proofs.** That is what the statements layer *is*.

- A **statement** is a boolean formula over claim types: `allOf: [UNIQUE_HUMAN,
  EVENT_ATTENDED_CANNES2026, STUDIED_SWITZERLAND, TAXES_PAID_2025]`. Your exact example.
- **Circuit A already proves a conjunction** of up to `MAX_CLAIMS = 4` claims in **one** local
  proof, emitting one per-app nullifier — unlinkable. (Bumping the max is a constant + a
  fixture-regen, not a redesign.)
- Each fact is acquired **once**, as a claim hanging off the user's one identity, and **reused
  forever** across every app.

So "combine many proofs into one" is a solved, proven-live primitive. What is *not* built is the
part the user actually feels:

1. **Breadth of evidence** — today only DKIM email (+ World ID). "Any signed document" means a
   **family of evidence circuits**, one per signature format.
2. **The upload-and-prove UX** — today the flow is hardcoded (World ID humanity, one Luma ticket)
   and proves **server-side**. The vision is: drop in a file, the app figures out what it is,
   proves it **in the browser**, and a claim appears in your wallet.
3. **A statement builder / claims wallet** — see what you hold; let an app request a bundle.

This doc designs those three, and nothing more — the aggregation engine underneath is untouched.

> **Update 2026-07-14 — persistence is now a per-fact choice, not a global assumption.** The
> "claim appears in your wallet" framing below describes the *persistent* path. §0.5 (added after a
> design discussion) establishes that most facts — emails especially — should default to **one-shot
> presentation** (nothing stored), with persistence as an opt-in. Read §0.5 before the rest; it
> changes which machinery the email path actually needs.

```
        WHAT THE USER SEES                     WHAT ALREADY EXISTS (unchanged)
   ┌──────────────────────────┐
   │  Upload a document        │
   │  ┌────────────────────┐   │   detect + route        ┌───────────────────────────┐
   │  │ ticket.eml         │───┼──────────────┐          │ Part A: VerifiedHumansTree │
   │  │ diploma.pdf        │   │              ▼          │ Part B: RedeemIssuer       │
   │  │ eid-credential.jwt │   │      evidence circuit    │ Claims: ClaimsSMTRegistry  │
   │  └────────────────────┘   │      (per format) ──────▶│ (opaque claim per fact)    │
   │                           │      binds C             └───────────────┬───────────┘
   │  My claims (wallet)       │                                          │
   │   ✓ human                 │                          ┌───────────────▼───────────┐
   │   ✓ Cannes 2026           │      one Circuit-A proof  │ Circuit A + EligibilityGate│
   │   ✓ studied CH            │◀─────────────────────────│ (conjunction, unlinkable)  │
   │   ✓ taxes 2025            │      over the bundle      │ StatementRegistry (the rule)│
   └──────────────────────────┘                          └────────────────────────────┘
```

---

## 0.5 Persistence vs one-shot presentation (2026-07-14 decision)

> **PROVEN LIVE 2026-07-14 (World Chain Sepolia).** The one-shot on-chain path works end to end
> with a **real Luma email** (Safe AI Lausanne / "Hack your way into LLMs"): a live Amazon-SES
> RSA-1024 DKIM signature verified in-circuit, `From: @calendar.luma-mail.com` + `"Registration
> (confirmed|approved) for X"` matched, event extracted, then one `present()` tx consumed the
> per-app nullifier (`isPresented` = true). No credential tree, no redeem, nothing stored.
> Pieces: `email_oneshot_proof/` (Circuit C one-shot, beta.5 + RSA-1024), `OneShotEmailGate`
> `0x936610F6cE762f20A1c26018c0eBa421B1e2fF6A`, OneShotEmailVerifier
> `0xf75Bc4576EEE1Fc228993a40394aF5f52c8C86Cf`, key + event registered in the existing
> `DKIMKeyRegistry` `0x7E132c…7F66`. Input generator: `demo-app/backend/make-oneshot-inputs.mjs`
> (targets the amazonses.com signature since Luma's aligned key rotates out).

> **COMPOSITION PROVEN LIVE 2026-07-14.** "Attended X AND Y" as one on-chain tx via
> `MultiEventEmailGate` `0x9D8700FDf097766Aa704f6706050Ed950E8d64D6` (safeai + trezor emails, shared
> nullifier = same person, coverage check). 9/9 unit tests. Deploy: `DeployMultiEventGate.s.sol`;
> event_ids via `demo-app/backend/make-eventid.mjs` (JS replication of the circuit hash, verified
> against nargo).

> **FULL BROWSER FLOW LIVE 2026-07-14 — no WSL, email never leaves the tab.** Frontend Step 6
> (one-shot) + Step 7 (compose) now do input-gen AND proving in the browser: `browserInputs.js`
> (DKIM verify + witness build, byte-identical to the backend — verified) + `browserProve.js`
> (NoirJS+bb.js, ~12s/email) → proof verifies against the deployed verifier (checked live) → one
> `present()`/`presentMany()` MetaMask tx. This closes the last privacy gap: the raw `.eml` is
> parsed, verified, and proven entirely client-side.

> **CROSS-TYPE COMPOSITION 2026-07-17.** `HumanEventGate` — "a verified HUMAN who attended events
> X..Z": composes a **World ID** personhood proof (different proof system) with N one-shot email
> proofs in one `present()`. The two can't share a nullifier (different systems), so they bind to
> the **caller**: World ID `signal = msg.sender`, email `app_id = appScope(msg.sender, stmt)`. World
> ID nullifier gives one-human-per-(statement,context) sybil resistance. 8/8 unit tests. This is the
> general pattern for adding any provider (Rarimo/zkPassport/…) to a composition. Deploy:
> `DeployHumanEventGate.s.sol` (needs the World ID Router + the frontend's IDKit app_id/action).
> Frontend Step 8 reuses the Step-2 World ID proof + browser email proofs. Also: the compose demo is
> now **3 events** (safeai + trezor + xrpl); `MultiEventEmailGate` supports up to 8 with no code
> change. The composition ladder: OneShotEmailGate (1 email) → MultiEventEmailGate (N emails, shared
> nullifier) → HumanEventGate (World ID + N emails, caller-bound).


The Phase-3 machinery (`VerifiedHumansTree` → `RedeemIssuer` → `ClaimsSMTRegistry`) bundles three
things into one mechanism, which makes it *look* like a fact must persist to be private. It doesn't.
This section separates the axes, says what persistence actually buys, and how to decide per fact.

### Three separate axes (not one)

| Axis | Question | Determined by |
|---|---|---|
| **Persistence** | is the fact stored for later reuse, or proven fresh each time? | your choice |
| **Privacy** | does the verifier see the underlying data (the email), or only the fact? | whether you prove in ZK |
| **Unlinkability** | can two apps correlate the proof to the same person? | what the proof's **public outputs** are |

A **one-shot** proof can be fully private *and* fully unlinkable: prove the email in ZK on-device
(the verifier never sees it), and emit a **per-app nullifier** `Poseidon(secret, appId, ctx)` rather
than any stable identifier — app A and app B then see uncorrelatable values. Nothing is stored. This
is in fact *more* private than persisting, because the claims-tree/redeem flow leaves an on-chain
footprint (a credential insert, a redeem) whereas a one-shot proof verified-and-discarded leaves
**zero** persistent trace. So the persistence↔privacy "intersection" isn't just possible; for emails
it is the sweet spot.

### What persistence actually buys

Persist a fact as a claim only when one of these holds:

1. **Expensive/inconvenient to re-acquire** — a World ID orb scan, a KYC flow. Don't redo it per app. (Personhood → persist.)
2. **Reused constantly across many apps** — amortize the proving cost.
3. **Evidence is perishable** — the one real argument *for* persisting emails: DKIM keys rotate and
   die (we observed a Luma `calendar.luma-mail.com` key already rotated to an empty `p=`). Once the
   key is gone the email is unverifiable forever; persisting a claim *while the key is live* freezes
   the verification result.
4. **Cross-time composition without re-presenting** — assemble facts gathered over months into one
   proof instead of re-uploading every source each time.

Stay **one-shot** when: used once here-and-now; cheaply re-verifiable on demand; **volatile** (balance
≥ X, "currently employed" — you *want* these fresh, never stored); or you want maximal privacy / zero
footprint.

### How to decide, and who decides

Not one global answer — per fact, and mostly auto-determined:

- **Volatile facts** → always one-shot / live-checked (a stored balance is a lie).
- **Expensive personhood** → persist by nature.
- **Everything in between (emails, tickets)** → default **one-shot**, persistence an explicit upgrade,
  decided by whoever has the context:
  - the **app/statement** can declare it needs a durable claim (e.g. a rewards program that keeps
    crediting "Cannes alumni") via a `mode: presentation | claim` flag;
  - the **user** can opt in — a "remember this so I don't re-upload next time" / "save as reusable
    credential" toggle, like "remember me on this device".

Rule: **default to one-shot; prompt only when it's genuinely a choice.** Don't ask for the ~80% that
is auto-determined (volatile → live, personhood → persist).

### The unifying trick — both kinds coexist in one statement

> **BUILT + TESTED 2026-07-14 (same-circuit case): `MultiEventEmailGate`.** A statement declares a
> *set* of required events; the user submits one one-shot proof per event in a single `present()`;
> the gate checks each proof verifies + covers a required event, that all proofs carry the **same
> nullifier** (same person — pooling two people's proofs reverts `NullifierMismatch`) and the same
> caller-bound `app_id`, then consumes the one nullifier. The **circuit and generator are unchanged**
> — run the one-shot circuit once per email with the same secret/app_id/context and the nullifiers
> match. 9/9 tests. Cross-*type* composition (email event AND World-ID personhood) is the same shape
> — any proof system emitting `Poseidon(secret, app_id, ctx)` shares the nullifier; only its verifier
> differs.


Both a persistent-claim proof and a one-shot proof can carry the **same** per-app nullifier
`Poseidon(secret, appId, ctx)`, because both know `secret`. So a statement like "human AND
attended-Luma" can be satisfied by a *persistent-claim* proof for humanity **plus** a *one-shot* proof
for the email — the gate checks both proofs share the nullifier (same person) and together cover the
required facts, then consumes it once. **Persistence becomes a per-fact implementation detail the
statement layer never sees.** Mixed freely.

### Decision for the email path

Emails default to **one-shot, private, unlinkable — no `ClaimsRegistry`/SMT** — with persistence an
opt-in for the middle-ground reasons above (chiefly key-rotation capture). This also removes the
machinery that made the earlier flow clunky: no `VerifiedHumansTree`, no `RedeemIssuer`, no claims-SMT
insert, no two-transaction redeem. Circuit C changes its public outputs from "emit `C` for insertion"
to **"emit a per-app nullifier + bind `idc` + reveal the statement-relevant fact"**, and the gate
verifies the proof + consumes the nullifier in one shot (on-chain, or off-chain for a pure access
check).

**What the proof reveals** is where residual linkability lives (independent of persistence). The email
proof exposes `event_id` (a commitment to the event token) and the gate pins it to the required event
— so the verifier learns *which* event, which is the point of the gate. A niche event is itself a
fingerprint; a statement that wants more privacy can instead require only "attended *some* Luma event"
or "an event by organizer X". Chosen per use case; the first cut reveals the specific event.

---

## 1. What "prove any document" honestly means

The framework's hard boundary applies unchanged, and the UX must be honest about it:

> **A document is provable iff it is cryptographically signed by a party you trust for that fact.**
> The proof *extracts* a signed truth; it never *creates* truth.

That splits every uploaded file into three buckets — and the router's first job is to sort them:

| Bucket | Examples | Provable? | What we do |
|---|---|---|---|
| **Signed-at-source** | DKIM `.eml`; signed PDF (PKCS#7/CMS, eIDAS); JWT/SD-JWT eID or OIDC credential; passport SOD | ✅ trustlessly (T0) | route to the matching **evidence circuit** |
| **Unsigned** | a screenshot, a typed letter, a plain PDF export, a photo of a certificate | ❌ nothing to verify | **reject + explain** (per decision): "this file isn't signed; upload the confirmation email / the eID credential instead" |
| **Login-only (no artifact)** | a bank balance page, a follower count | ⚠️ only via zkTLS (T1, witness-trusted) | out of scope here; the separate zkTLS track |

The "reject + explain" path is a **feature**, not a failure: it teaches the user *where the
provable version of their fact lives*. A person who uploads a scanned diploma gets told "diplomas
issued as an EU eID credential (a `.json`/`.jwt`) can be proven — a scan can't," which is exactly
the guidance that makes the system usable.

---

## 2. The evidence-circuit family (the extensibility spine)

Each signature **format** needs its own in-circuit verifier — DKIM-RSA, CMS/X.509, JWT-ES256 are
genuinely different cryptography and cannot share verification code. **This is the one irreducible
per-format cost**, exactly as each personhood provider needed its own adapter. Everything *around*
it is generic and already written.

### 2.1 The invariant contract every evidence circuit satisfies

To slot into the existing machinery, an evidence circuit — whatever the format — must expose the
**same 5-value public interface** Circuit C already established:

```
[0,1] doc_key_hash     : commitment to the signing key (contract maps key -> issuer/domain)
[2]   content_id       : commitment to the matched discriminator (WHICH fact: which event,
                         which country, which tax year) over SIGNED bytes only
[3]   evidence_nullifier: deterministic per document (one document -> one credential, ever)
[4]   cred_commitment  : C = Poseidon2(secret, r) — the identity binding (unchanged)
```

If a new circuit produces those 5 outputs, **`EmailEvidenceVerifier`'s logic works verbatim** —
verify proof → check key in a registry → pin `content_id` → consume nullifier → `insertCredential(C)`.
So the generalization is: rename `EmailEvidenceVerifier` → a generic **`DocumentEvidenceVerifier`**
(or keep per-format thin wrappers over a shared base) whose only per-format knob is *which verifier
contract* and *which key registry* it calls. The key registry generalizes `DKIMKeyRegistry` →
`IssuerKeyRegistry` (domain/issuer → allowed signing keys, with retirement).

> **Design rule:** the evidence circuit is the *only* new artifact per format. No new claims tree,
> no new redeem flow, no new eligibility circuit, no app change — identical to the "adding a
> provider is O(1)" property we already proved for personhood providers.

### 2.2 The ladder (leave the ordering open, per decision)

| Format | Signature scheme | In-circuit cost | Library | Facts it unlocks |
|---|---|---|---|---|
| **DKIM email** ✅ | RSA-2048 over headers | done, cheap (header-only) | `zkemail.nr` | tickets, receipts, "you registered", order confirmations |
| **JWT / SD-JWT** | ES256 (P-256) / RS256 over compact JSON | light–medium | zk-JWT (Noir ports emerging) | eID/gov credentials, OIDC logins, KYC, "studied at X", verifiable-credential wallets |
| **Signed PDF** | PKCS#7/CMS + X.509 chain | heavy (cert-chain verify) | none turnkey in Noir yet | eIDAS-qualified documents, DocuSign, official letters, tax docs |
| **Passport SOD** | RSA/ECDSA over data groups | medium | (Rarimo/zkPassport already cover personhood) | nationality, age — mostly covered by existing providers |

We do **not** pick the next rung here. The point is the *slot* is generic; when a real need
(a design partner wanting "tax paid" or "studied in CH") lands, we build that one circuit against
this interface and everything else is config.

### 2.3 Content-specificity generalizes cleanly

Circuit C's `check_subject_token` (a token in a signed header) is the DKIM instance of a universal
gadget: **match a discriminator inside signed bytes, commit it as `content_id`, pin it on-chain per
source.** JWT: match a claim field (`{"degree":"MSc","institution":"ETH Zürich"}`) inside the
signed payload. PDF: match text in the signed content stream. Same shape, different byte layout —
and the same never-trust-unsigned rule (only bytes under the signature count).

One nuance worth flagging now: richer facts want **structured** discriminators (issuer + field +
value), not a single 32-byte token. Plan `content_id = Poseidon(issuer_id, field_id, value_hash)`
so "ETH Zürich · degree · MSc" and "taxes · year · 2025" are expressible. The email circuit's
single-token form is the degenerate case.

---

## 3. Browser proving (the privacy upgrade)

Today the backend proves server-side (`prove.js` shells `nargo`+`bb`), which means it **sees the
document** — acceptable for the CLI PoC, fatal for the "upload your diploma" vision. Decision:
**move proving into the browser** so the file never leaves the device.

### 3.1 What changes

- **Circuits compile to WASM + a proving artifact** (`nargo compile` → ACIR; `bb.js` / NoirJS in
  the browser generates witness + UltraHonk proof). The backend stops touching documents entirely;
  it returns only *calldata assembly* and *chain reads* (staying keyless, as designed).
- **Input generation moves client-side.** The `make-*-inputs.mjs` logic (DKIM parse → limbs,
  discriminator location) runs in-browser over the uploaded file. For email this is the
  `@zk-email/zkemail-nr` generator, which is already JS and browser-capable.
- **The user's `secret` stays on-device** (it already never leaves in the design; today the demo
  backend holds it for convenience — browser proving forces the correct model where the wallet/
  device custodies `s`).

### 3.2 The risk to validate first (spike before committing)

> **SPIKE SUCCEEDED 2026-07-14.** Browser proving of the one-shot Circuit C works end to end and the
> proof **verifies against the deployed on-chain verifier** (`eth_call verify()` → true — the real
> version-match test, not a bb.js self-check). Stack: `@aztec/bb.js@0.84.0` + `@noir-lang/noir_js@
> 1.0.0-beta.5` (bb.js version MUST equal the beta.5 `bb` that built the verifier — `bb --version`
> = 0.84.0). Witness gen is byte-identical to nargo (public inputs matched exactly). **Perf ~27.5s**
> (≈2s witness + ≈25.5s prove) for RSA-1024/SHA-256 in WASM. Vite config: `optimizeDeps.exclude` bb.js
> + noir_js, `esnext` target, `worker.format: es`, COOP/COEP `same-origin`/`require-corp` headers.
> Module: `demo-app/frontend/src/browserProve.js`.
>
> **LOOP FULLY CLOSED 2026-07-14.** (1) In-browser INPUT generation done —
> `demo-app/frontend/src/oneshotInputs.js` runs zkemail-nr + the extraction in the browser, so the
> `.eml` is parsed **entirely on the device** (~1.5s) and never touches a server. End-to-end verified
> headlessly on a real Luma email: parse → inputs → browser prove → on-chain `verify()` = true, with
> `event_id` matching the deployed statement. (2) COEP dropped — **no COOP/COEP headers** (World-ID
> iframe unaffected); bb.js runs single-threaded fine (~12–27s). One-click UI wired in Step 6
> ("Prove in browser & present"): upload `.eml` → in-browser input-gen + prove → `present()` in one
> tx; the WSL path stays as an "Advanced" fallback. So the one-shot email flow is now fully private
> and WSL-free in the browser.


RSA-2048 + SHA-256 in-circuit is heavy; **in-browser proving time and memory are the open
question.** Mach-34 publishes `zkemail.nr` browser benchmarks (seconds–tens of seconds range),
so it's plausible, but the **first build task is a browser-proving spike** on the *existing* email
circuit: compile to WASM, prove one email in the browser, measure. If it's minutes, we add a
"prove on a local helper" fallback or a WASM worker with progress UI — but we learn that before
building the whole UX on top.

### 3.3 Honest interim

Until the spike passes, the design supports a **toggle**: browser proving when it works, the
current backend proving as a clearly-labeled "less private, faster" fallback for demos. The
end-state is browser-only; we don't pretend server proving is private.

---

## 4. Frontend architecture — the three new surfaces

The current [`App.jsx`](../demo-app/frontend/src/App.jsx) is a hardcoded Alice/Bob script. The
vision needs three composable surfaces. All reuse the existing keyless-backend + MetaMask pattern.

### 4.1 The document dropzone + router

One upload control that accepts anything and routes it:

```
file dropped
  → sniff type (extension + magic bytes + structure):
      .eml / RFC822            → DKIM evidence flow            (built)
      .pdf with /Sig object    → PDF-CMS evidence flow         (future circuit)
      .jwt / SD-JWT / .json VC  → JWT evidence flow             (future circuit)
      signed but unknown issuer → "issuer not recognized yet"  (governance must register the key)
      no signature detected     → REJECT + explain (decision)  — suggest the signed source
  → for a routable file: generate inputs in-browser → prove → submitEvidence → redeem
  → a claim appears in the wallet (§4.2)
```

The router's "reject + explain" branch is first-class UX copy, not an error toast: name the fact,
say why the file can't prove it, point to the provable source.

### 4.2 The claims wallet

A dashboard of what the identity holds — the "aggregation" made visible:

```
My ZuitzPass                                    idc ••••  (hidden, on-device)
  ✓ Unique human            World ID       exp 2026-09   [renew]
  ✓ Cannes 2026 ticket      luma .eml      exp —          
  ✓ Studied in Switzerland  ETH eID .jwt   exp 2027-01
  ⧗ Taxes paid 2025         upload document…
```

Reads come from `ClaimsSMTRegistry` (leaf existence per `Poseidon2(idc, claimType)` the client can
recompute) — no new contract. This is where "renew" (the spun-off `RedeemIssuer` renewal task)
surfaces, and where expiry is visible.

### 4.3 The statement bundler (app side, "Bob")

Today Bob creates only `allOf:[UNIQUE_HUMAN]`. Generalize to a **picker**: choose the required
claim types from the registered catalog → `registerStatement(allOf:[...])`. Then Alice's "join"
proves the whole bundle in one Circuit-A proof (already supported up to `MAX_CLAIMS`). A gate that
requests "human + Cannes + studied-CH + taxes-2025" is just a 4-element `allOf` — the machinery is
identical to the 1-element case we run today.

---

## 5. Backend changes (small, and it gets *less* trusted)

The keyless backend shrinks. Per route:

| Today | After |
|---|---|
| `/alice/register` mints `s` server-side | `s` generated in-browser; backend never sees it |
| `/alice/redeem`, `/alice/join` prove server-side (sees witness) | proving in-browser; backend only assembles calldata + reads chain |
| `/vouch/verify-email` verifies DKIM server-side (sees the email) | replaced by in-browser Circuit-C proving; backend just reads the resulting claim |
| hardcoded claim types / single statement | serves the **registered catalog** (claim types + statements) for the wallet/bundler to render |

Net: the backend moves fully to "read chain + encode calldata," which is the honest end-state of
the keyless design. New/changed contracts from §2 (generic `DocumentEvidenceVerifier`,
`IssuerKeyRegistry`) are the only Solidity, and they're generalizations of shipped contracts.

---

## 6. Honest gaps & risks (surface them now)

1. **Browser proving is unproven for us** — §3.2. Gate the whole UX behind the spike; measure
   before building.
2. **PDF/CMS in Noir is genuinely hard** — no turnkey library; X.509 chain verification is a large
   circuit. If PDF is the priority, budget real circuit R&D (or accept a T1 attestor stage for PDFs
   short-term, per the framework's staging rule).
3. **Template/format fragility** — every real source (a specific university's eID, a specific tax
   authority's PDF) needs a per-issuer content-match analysis (framework method, step 2). This is
   ongoing onboarding work, not one-time.
4. **Issuer-key governance scales** — `IssuerKeyRegistry` must hold keys for *every* recognized
   issuer (every university, airline, tax authority). That's a real governance/curation burden;
   consider leaning on ZK Email's public DKIM registry and eID trust lists rather than curating
   solo.
5. **`MAX_CLAIMS = 4`** — the Cannes example (human + ticket + studied + taxes) is exactly 4. A
   5-fact bundle needs the constant bumped + fixtures regenerated (cheap, but not zero).
6. **Anonymity-set fragmentation** — one tree per (issuer, fact) means niche facts have tiny
   anonymity sets. Shared trees per fact-type help; note it per source.
7. **Sybil, always** — new facts are attributes; statements must keep composing with `UNIQUE_HUMAN`
   (§ framework I7). The bundler UI should nudge/deny attribute-only statements.

---

## 7. Proposed build order (each phase independently useful)

0. **Browser-proving spike** on the existing email circuit — compile to WASM, prove one email
   in-browser, measure time/memory. **Go/no-go gate for everything else.**
1. **Wire the email flow into the real frontend** — the dropzone (email branch only) + in-browser
   Circuit-C proving + `submitEvidence` → the claims wallet shows the ticket. This is the shipped
   feature, made usable, and validates the whole client-side pipeline on the one format we have.
2. **Generalize the contracts** — `EmailEvidenceVerifier` → `DocumentEvidenceVerifier`,
   `DKIMKeyRegistry` → `IssuerKeyRegistry`, `content_id` → structured form. No new circuit yet;
   just make the slot generic and re-run the email path through it.
3. **Statement bundler** ("Bob" picker) + **claims wallet** with renew — the aggregation made
   visible and composable, still on email + World ID only.
4. **Second evidence circuit** (format chosen later, per the open decision) against the §2.1
   interface — proving the generality with a real second document type end to end.
5. **Unsigned-doc UX polish** — the router's detect-and-explain copy, issuer-not-recognized
   handling, the "provable source" suggestions.

Phases 0–3 need **no new circuit** and deliver the "upload a signed email, see it in my wallet,
an app bundles it with humanity" experience end to end. Phase 4 is where "any document" literally
broadens — and by then it's a plug-in, not a project.

---

## 8. One-paragraph summary for the team

The proof-*aggregation* engine already exists and is proven live: a statement is a conjunction of
claims, Circuit A proves the whole bundle unlinkably in one shot. What we're adding is (a) a
**family of evidence circuits** — one per signature format, each exposing the same 5-value
interface the email circuit established, so every new format is a plug-in into unchanged
downstream machinery; (b) a **browser-proving** pipeline so uploaded documents never leave the
device; and (c) the **UX** — a document dropzone that routes any signed file to the right circuit
(and clearly rejects unsigned ones), a claims wallet, and a statement bundler. First we spike
browser proving, then wire the email format we already have into that full experience; broadening
to PDFs/eID credentials is then adding one circuit at a time, not a redesign.
