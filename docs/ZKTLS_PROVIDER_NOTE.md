# zkTLS as a future provider for ZuitzPass

_Status: V2 exploration note — not implemented. Captures the idea, the integration path,
and the trade-offs so we can decide later._

## What zkTLS is (in brief)

Normal HTTPS (TLS) guarantees a secure channel between **you** and **a website**. But it
gives you no way to prove to *someone else* that "the website really told me X" without
just handing over your raw session — which leaks your credentials and lets you fake data.

**zkTLS** closes that gap: it lets a user prove a **fact about a real web response**
(from any Web2 site/API) to a third party, **without revealing the underlying data or
login**. It works by having a notary/proxy witness the encrypted TLS session, after which
the user produces a zero-knowledge proof over the response. The verifier learns only the
claimed fact — nothing else.

**Example.** Zuitzerland runs registration through a Web2 portal (Eventbrite, a Notion/
Airtable, an email confirmation). With zkTLS a user could prove *"the registration API
says my email is on the confirmed attendee list"* — without revealing their email, name,
or the full API response. The forum learns only "this person registered for the event."

## Why it's relevant to ZuitzPass

Today ZuitzPass gates on **passport credentials** (Rarimo, zkPassport) — strong proof of a
unique human. zkTLS adds a different axis: **attribute / eligibility gating from Web2
data** ("you registered for the event", "you're in org X", "your account is older than N").
For an event-based pop-up community, *"prove you're on the guest list"* is a very natural
gate, and that truth usually lives in a Web2 system zkTLS can attest to.

## How it would integrate — as a third provider, no core changes

ZuitzPass is **provider-agnostic**: Circuit 1 and `ZuitzerlandVerifier` only care about SMT
membership, and we already have a per-provider **adapter** abstraction. zkTLS slots in as a
new provider behind a **registrar bridge**:

```
1. User generates a zkTLS proof of a Web2 fact (e.g. "registered for Zuitzerland").
2. A zkTLS Registrar contract verifies that proof on-chain and, on success, mints the
   user's commitment into the SHARED ERC-7812 SMT
   (at getIsolatedKey(zkTLSRegistrar, key) — same isolation model as the other providers).
3. From here ZuitzPass is UNCHANGED:
     - the user proves membership with the existing Circuit 1
     - ZuitzerlandVerifier runs its 4 checks exactly as today
     - we just register a new `ZkTLSAdapter` (its registrar address + a validity window)
```

So the cost is: **a zkTLS→registrar bridge + one new adapter** — not a redesign. The fact
that it drops in this cleanly is itself a good sign the provider-adapter design is sound.

```
zkTLS proof ──▶ zkTLS Registrar ──▶ commitment in shared ERC-7812 SMT
                                         │
                                         ▼
              existing Circuit 1  +  ZuitzerlandVerifier  +  ZkTLSAdapter
              (membership proof)      (unchanged gate)        (registrar + window)
```

## Trade-offs to weigh

**The big one — Sybil resistance.** Passport providers are strong "one person = one
member" signals (one human, one passport, one nullifier). zkTLS-attested Web2 data usually
is **not**: one person can hold many GitHub/Discord/email accounts. zkTLS is great for
*"you have property P"* but weak for *"you are a unique person"*. Since ZuitzPass bans by
nullifier and wants to resist sock-puppets, zkTLS should likely be an **additional or
weighted** credential — e.g. "passport OR (zkTLS event-registration AND …)" — not a sole
gate, unless the underlying Web2 source is itself identity-bound (a KYC'd account).

**Other considerations (lighter):**
- **Trust model.** zkTLS adds a trust assumption our pure-ZK passport path doesn't have:
  MPC-TLS relies on a notary; the proxy model relies on a witness. Pick a scheme whose
  assumptions are acceptable.
- **Performance / liveness.** MPC-TLS handshakes are heavier than generating a local proof.
- **On-chain bridging.** The attestation must be verified on-chain (the registrar) to fit
  our registry-centric model; that registrar's correctness becomes security-critical.
- **Web2 fragility.** The attested API can change, rate-limit, or go down; gating on it
  couples membership to a third party's uptime and response format.

## Recommendation

- **PoC:** do **not** add zkTLS yet — the two passport providers are the right MVP, and the
  Sybil caveat needs a policy decision first.
- **V2:** strong candidate, specifically for **event/community eligibility gating**, where
  Web2 is the source of truth. It extends ZuitzPass without touching Circuit 1 or the core
  contracts — only a registrar bridge and a new adapter.

---

# Vouch — concrete zkTLS provider (current architecture)

_Added 2026-07-10. The section above is conceptual background written against the archived
Path-B stack (Circuit 1 / ERC-7812 SMT / adapters). This section maps zkTLS onto the
**shipped** architecture — Evidence → Claims → Statements — and supersedes the old
integration path for any real work._

> **DECISION (2026-07-10): ship Vouch as a Phase-1 pseudonymous provider.** Integrate via the
> **attestor webhook path** using `metadata` for correlation — no new circuits, no on-chain
> Web Proof verification, no `idc` binding. The **Phase-3 unlinkable upgrade is parked as a
> side note** (see "Phase-3 upgrade — parked" and "Questions for the Vouch team" below); it's
> blocked on confirming vlayer `Prover` access with their team, and isn't needed for v1.

## What Vouch is

[Vouch](https://docs.getvouch.io) is a **zkTLS attestation platform** (TLSNotary via
vlayer Web Proofs). The user's own device opens a TLS session to some web service — bank,
employer portal, gov site, social account, **Luma** — and produces a cryptographic
attestation about the *contents* of that session ("income > X", "employed at Y", "owns
this ticket") **without the business seeing the underlying data**. Off-chain, delivered by
webhook, with an `@getvouch/sdk`. Works on Chrome/Edge desktop + iOS + Android, no chain
required on their side.

## Why it's the right third provider

Our two current providers both prove **personhood**:

| Provider | Proves |
|---|---|
| World ID | unique human |
| Passport (Rarimo / zkPassport) | over-18, nationality |
| **Vouch (zkTLS)** | **arbitrary web-account facts** — income, employment, residency, social identity, **event/ticket ownership** |

Vouch fills the gap the personhood providers structurally can't: **attribute claims sourced
from Web2 truth.** It's the concrete product for the zkTLS slot the extensibility principle
always anticipated — and it's the natural answer to "prove you're on the Cannes-2026 guest
list."

## Integration — the attestation rung, zero new circuits

Vouch lands at the **attestation rung** of the evidence ladder, so it reuses
`AttestorIssuer` exactly as designed. **No new Noir circuit, no change to the gates.**

```
User device ──zkTLS / vlayer Web Proof──▶ Vouch verifies
                                              │  webhook (HMAC secret)
                                              ▼
                                    demo-app backend  (attestor signer)
                                              │  EIP-712 attestation
                                              ▼
                                    AttestorIssuer.issue(subject, claimType, expiresAt)
                                              │
                                              ▼
                                     ClaimsRegistry  ──▶ StatementRegistry.check / consume
```

**Adapter shape (what you actually build):**
1. A **Vouch webhook receiver** in `demo-app/backend/` — validates the HMAC secret, parses
   the presentation, extracts the fact.
2. The backend is already an **allow-listed attestor signer** on `AttestorIssuer`; it maps
   the verified fact → a registered claim type and calls `issue`.
3. Register the new claim types on `ClaimsRegistry` (owner tx). No Solidity beyond claim-type
   registration.

**Claim types to register first** (`keccak256(name) mod p`, matching the existing convention):
- `EVENT_TICKET_LUMA` — owns a paid/confirmed ticket to a specific Luma event.
- `INCOME_OVER_THRESHOLD` — income attestation (short validity — financial data is volatile).
- `EMPLOYED_AT_ORG` — active employment at org X.
- `RESIDENCY_COUNTRY` — residency from a utility/gov account.

Suggested validity windows: ticket = until event end; income/employment = 7–30 days (they
change); residency = 90 days.

## Phase-1 integration (what we ship)

The SDK exposes two developer-controlled channels (docs: Handling Inputs + Verifying
WebProofs, 2026-07-10):
- `inputs` — a JSON object on `getDataSourceUrl({ datasourceId, inputs, ... })`: **data-source
  request parameters** (e.g. `{ twitter_username }`) that drive which TLS session is notarized.
- `metadata` — an **"optional free-form string you attach to the proof request,"** echoed back
  in the webhook alongside `requestId` (their example: `"internal_user_id:12345"`). This is
  the **correlation** channel we use.

**Phase-1 flow — works today, zero friction, no circuits:**
1. Backend calls `getDataSourceUrl(...)` with `metadata` = the subject (or an `idc`
   commitment), `webhookUrl` = our receiver.
2. User completes the zkTLS flow on their device.
3. Webhook fires → backend validates the HMAC secret, reads `outputs` + `metadata`, maps the
   verified fact → a registered claim type.
4. Backend (an allow-listed `AttestorIssuer` signer) calls `issue(subject, claimType, expiresAt)`.
   `subject = keccak256("vouch", accountHandle)` if the source exposes a stable handle.

Trust model: Phase-1 trusts *Vouch's verifier + our attestor signer* — same trust class as
`AttestorIssuer` already carries. Acceptable for v1 attribute gates.

### What we actually built (2026-07-10): DKIM email verification

Rather than mock the verification, the shipped spike does a **real** check without any Vouch
account: Alice uploads her Luma **confirmation email (`.eml`)** and the backend verifies
**Luma's DKIM signature** over it (RSA, public key in `lu.ma`'s DNS). Forged/edited emails fail
the signature check. This is the same "signed-document" mechanism Vouch/zk-email use — a Luma
email is already signed by `lu.ma`, so no notary and no live session are needed — **minus the ZK
privacy wrapper**, which is exactly the Phase-3 upgrade (move this same DKIM check inside a
circuit + bind `idc`, e.g. via vlayer Email Proofs / zk-email).

Implementation: `demo-app/backend/dkim.js` (`mailauth` verify) + `POST /api/vouch/verify-email`
→ `AttestorIssuer.attest`. `subject = keccak256("luma:" + recipient)` from DKIM-signed headers
only; the email content-hash is the single-use guard. Runbook + self-signed test path (no real
inbox needed): `demo-app/backend/VOUCH_SPIKE.md`. Verified: valid → pass, tampered → reject,
replay → 409.

## Phase-3 upgrade — parked (side note)

Not built in v1. Captured so we don't re-derive it later.

The docs are explicit that **`metadata` is NOT cryptographically bound to the proof** — it's a
passthrough label on the *request*, not committed into the notarized transcript or
`presentationJson`. So for the unlinkable path a *stolen* webproof (e.g. Alice's ticket proof)
could be re-submitted under a *different* `idc`. **Correlation ≠ binding**, so `metadata`
alone cannot secure Phase-3.

**The likely fix — trust and binding are the same decision.** Vouch runs on **vlayer Web
Proofs, which are EVM-verifiable**: verify one inside a vlayer `Prover` contract where **we
control the public inputs**, and *require the proof commit to `idc`* (exactly like World ID's
`signal_hash`). That single move gives both trustlessness and strong binding.

| Path | Trust | `idc` binding | Effort | Phase |
|---|---|---|---|---|
| Attestor webhook (`metadata`) | trust Vouch + our signer | correlation only | low | **v1 (shipping)** |
| On-chain vlayer `Prover` | trustless | **real binding** of `idc` as committed public input | higher | parked |

## Questions for the Vouch team

Answers to these unblock (or rule out) the Phase-3 upgrade. Send before committing to it.

1. **Raw webproof / on-chain path.** Does `@getvouch/sdk` expose the underlying **vlayer Web
   Proof / `Prover`** so we can verify a presentation **on-chain ourselves**, or is
   verification only available through your hosted webhook / `/api/v1/verify` endpoint?
2. **Binding an external value.** Is there any way to bind a **caller-supplied value (our
   `idc`)** *into* the proof so it's cryptographically committed — not just echoed like
   `metadata`? (e.g. a signal/nonce that lands inside `presentationJson`, or a `Prover` input.)
3. **`metadata` integrity.** Confirm explicitly: is `metadata` ever part of the signed/
   notarized material, or purely a server-side label attached to `requestId`?
4. **Replay / single-use.** Is a given webproof **single-use**? What's the stable field we can
   dedup on (transcript hash? `requestId`? a nullifier?) to enforce one-webproof-per-subject
   and prevent a captured proof being re-submitted?
5. **Notary trust assumptions.** Who runs the TLSNotary/notary in production, and what's the
   trust assumption (single notary? MPC? vlayer-operated?) — so we can state it honestly.
6. **Data-source authoring for Luma.** Is there a ready **Luma / lu.ma** data source (ticket /
   attendee status), or do we author a custom one? What `outputs` does it expose (event id,
   ticket status) without leaking email/PII?
7. **Rate limits / liveness.** Per-user handshake latency and any rate limits we should design
   the UX around.

## Sybil caveat (unchanged, still important)

Web2 accounts are **not** one-per-human — a person can hold many GitHub/email/Luma accounts.
So Vouch claims are **attribute** claims, not **personhood** claims. In statements, compose
them *with* a personhood claim, never as a sole gate:
`allOf: [UNIQUE_HUMAN_WORLDID, EVENT_TICKET_LUMA]` — "a unique human who also holds the
ticket," not just "someone who holds a ticket."

## Worked example — "Cannes 2026 ticket-holders lounge"

Bob runs a token-free, privacy-preserving lounge open only to **verified humans who hold a
paid Cannes-2026 Luma ticket**, and he must not be able to track who showed up.

**Setup (Bob / owner, once):**
1. Register claim type `EVENT_TICKET_LUMA` on `ClaimsRegistry`.
2. Create a statement `CANNES_LOUNGE = allOf:[UNIQUE_HUMAN_WORLDID, EVENT_TICKET_LUMA]` on
   `StatementRegistry` (this is exactly the existing `RegisterDemoStatement` pattern).

**Alice's flow:**
1. She already did World ID → holds `UNIQUE_HUMAN_WORLDID` (existing demo path).
2. In the demo app she clicks *"Prove Luma ticket."* The `@getvouch/sdk` opens the zkTLS
   flow against `lu.ma`; her device proves *"my account holds a confirmed ticket to event
   evt_cannes2026"* — **binding her `idc` as the signal** (Phase-3) — without revealing her
   email, name, or the order details.
3. Vouch verifies → webhook → backend validates HMAC → maps to `EVENT_TICKET_LUMA` → issues
   the claim (into the claims SMT under her `idc` leaf for the unlinkable path).
4. Alice generates the **eligibility proof** (existing Circuit A) for `CANNES_LOUNGE`; the
   app calls `EligibilityGate.consume`. She's admitted.

**Privacy result:** the lounge learns only *"a unique human holding a valid Cannes ticket
entered"*, sees a **fresh per-app nullifier** (not her identity, not her Luma account), and
cannot link her to any other app — while Vouch never exposed her ticket details to Bob and
Bob's contract never saw her email. This is the whole thesis in one flow: **a Web2 fact
(Luma) + a personhood fact (World ID), composed into an app gate, revealing nothing else and
un-linkable across apps.**

## Recommendation (Vouch)

**Ship it now as the third provider (zkTLS), Phase-1 pseudonymous, via `AttestorIssuer`, no
new circuits.** Highest-leverage addition available: it unlocks a *category* of claims
(financial, employment, residency, ticket ownership) rather than another flavor of personhood,
and it's the cleanest possible proof that the neutral-layer design works — adding a provider is
an adapter plus a claim-type registration, not a redesign. The **Phase-3 unlinkable upgrade is
parked**, pending answers to the "Questions for the Vouch team" above (chiefly: can we verify
the vlayer Web Proof on-chain and bind `idc` into it).

---

# How far Vouch generalizes — the provability boundary

_Added 2026-07-10. FAQ-style, for colleagues. Answers: what kinds of facts can this prove, and
what does adding one cost us structurally?_

## The one principle

A proof is only possible because **a trustworthy source already attests to the fact.** The
proof system (zkTLS, DKIM/zk-email) does **not create truth** — it *extracts a fact from a
source that's already trusted* and lets you present it (optionally privately). Two "anchors":

1. **A live web session** → zkTLS / Web Proofs (a notary co-witnesses your HTTPS session with a
   site you log into).
2. **A pre-signed document** → email (DKIM), or any issuer-signed artifact (signed PDF, etc.).

## What can it prove?

**Any fact a trustworthy online source already attests to.** The limiting factor is never
Vouch — it's whether the fact has a trustworthy digital footprint.

- ✅ Anything visible when **you log into a website** (bank balance, order history, employment
  portal, subscription status, follower count).
- ✅ Anything in a **signed document/email** (DKIM confirmation, signed receipt).
- ❌ Facts with **no trustworthy digital source** — cash paid in person, a verbal agreement, an
  unsigned document you typed yourself. There is nothing to verify.

### Worked example — "I paid rent in May 2025 at location X"

Provable? It depends **entirely on where that truth lives**:

| How rent was paid | Provable? | How |
|---|---|---|
| Bank transfer / standing order | ✅ | zkTLS into online banking → "a €X transfer to landlord Y on 2025-05-03" |
| Payment app (PayPal, Wise, a rent portal) | ✅ | zkTLS into that account's transaction page |
| Landlord sent a **receipt email** | ✅ | DKIM email proof (identical to the Luma case) |
| Cash + paper receipt, no digital trace | ❌ | nothing trustworthy to verify |

**Fidelity caveat:** you prove the *raw fact the source exposes* — e.g. "a €1,200 transfer to
IBAN …, dated 2025-05, memo 'rent'." Turning that into "rent at 12 Rue de Cannes" requires
**interpreting the counterparty/memo**. You prove what the source says and compose meaning
around it; if the source never names the location, Vouch can't conjure it.

So the extent: **Vouch proves online-attested facts, not ground truth.** It bridges "a trusted
website/document says X" → "an on-chain claim that X holds," privately.

## Impact on our existing structure — additive, bounded blast radius

Adding a Vouch fact = **a new claim type + an adapter**, not a redesign:

| Component | Impact of adding a Vouch fact |
|---|---|
| **ClaimsRegistry** | **+1 claim type per fact** (`RENT_PAID_MAY2025`, `INCOME_OVER_X`, …) + `setIssuer` to permit the attestor. No code change — this is what it's for. |
| **AttestorIssuer** | The **integration point**. Every Vouch-style provider rides through it (verified fact → `issue`). Nothing new per fact. |
| **StatementRegistry** | **Untouched.** Apps compose the new claims: `allOf:[UNIQUE_HUMAN, RENT_PAID_MAY2025]`. |
| **VerifiedHumansTree / RedeemIssuer / EligibilityGate** | **Not touched by Phase-1 Vouch at all** — those are the Phase-3 *unlinkable humanity* machinery; Vouch Phase-1 issues into the pseudonymous ClaimsRegistry, a separate path. |
| **Circuits (A & B)** | **No new circuits.** The statements layer never needs one to add a fact. |

Mental model: **the registries are a neutral bus.** World ID, passports, Luma tickets, rent
receipts, income — each is just another issuer writing a typed claim onto that bus; apps read
claims by name and compose them into statements. The tenth provider costs the same as the
third: register a claim type, wire an adapter, done. (The only time Vouch touches the trees/SMT
is the Phase-3 upgrade — verify the proof *in a circuit* and bind `idc` — and even then it
reuses the existing provider-tree pattern, still no new statements-layer circuits.)

**Sybil boundary (always):** Vouch facts are **attribute** claims, not **personhood** — one
human can hold many bank/email/rent accounts. Always compose with a personhood claim
(`allOf:[UNIQUE_HUMAN, RENT_PAID]`), never gate on the attribute alone.

---

# Why we haven't integrated the Vouch SDK yet

_Added 2026-07-10. This was a deliberate call, not an oversight — recorded so colleagues don't
mistake the DKIM spike for "we couldn't get Vouch working."_

**1. It's access-gated and we don't have an account.** Vouch runs behind a waitlist
(`accounts.getvouch.io/waitlist`); the `@getvouch/sdk`, the data-source catalog, and an API key
all require an approved account. Without credentials we can't call `getDataSourceUrl` or run a
real verification — integrating the SDK now means writing code we can't execute or test. (We
*did* build the scaffolding around it — the `/api/vouch/webhook` receiver, HMAC verify,
`/start`, the assumed payload schema in `vouch.js` — so the SDK slot is stubbed and ready. What's
missing is the account, not the wiring.)

**2. The make-or-break question is unanswered.** Vouch's advantage over plain DKIM is privacy +
unlinkability (Phase-3), which hinges on one open question for their team: does the SDK expose
the vlayer `Prover` / raw web-proof so we can verify it on-chain and bind `idc`? Until answered,
integrating the SDK risks locking in a design we'd have to redo.

**3. DKIM let us build the *real* thing today, dependency-free.** Vouch's email-proof path *is*
DKIM (their Email Proofs are DKIM-over-vlayer). By verifying the DKIM signature ourselves we got
a genuine cryptographic check — runnable now, no account, no cost, no third party — that
exercises the **exact integration shape** (`verify → attest → claim`). Swapping in Vouch later
is a **drop-in at one function** (the verify step / `parseVouchPayload`), not a rewrite. We
de-risked the integration without taking the dependency.

## When we *would* pull in the SDK

Any one of these becoming true:
- A fact you need lives **only behind a login** (no DKIM-signed email exists for it) → you need
  zkTLS, which is Vouch's territory, not DKIM's. (Luma has a signed email, so DKIM sufficed; a
  bank *balance* with no email would not.)
- You need the verification to be **private / unlinkable** (backend must not see the data) →
  the in-circuit path, gated on their `Prover` answer.
- You get **catalog access** and want their pre-built data sources instead of hand-rolling a
  verifier per source.

**Net:** DKIM covers "signed-document" facts today; Vouch's SDK is the upgrade for "login-only"
facts and for privacy. We built the first and left a clean seam for the second.
