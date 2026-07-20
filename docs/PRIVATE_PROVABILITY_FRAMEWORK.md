# Proving anything provable, privately — framework + event-attendance design

> New to the project? Read [`READ_ME_FIRST.md`](../READ_ME_FIRST.md) first — it frames where this
> doc sits (this is *the why*: the invariants and the method).

_Written 2026-07-13. Design note, no code changed. Answers: "how do we prove **any** fact,
**privately**, in a way that slots into the Evidence → Claims → Statements layer?" Grounded in
the #1 live fact — event attendance — then generalized. Settled context this builds on (and
does not contradict): [`contracts/ARCHITECTURE_UPDATED.md`](../contracts/ARCHITECTURE_UPDATED.md),
[`contracts/PHASE3_UNLINKABLE_DESIGN.md`](../contracts/PHASE3_UNLINKABLE_DESIGN.md),
[`docs/ZKTLS_PROVIDER_NOTE.md`](ZKTLS_PROVIDER_NOTE.md), the DKIM spike
(`demo-app/backend/dkim.js`, `VOUCH_SPIKE.md`)._

**Decisions encoded (agreed 2026-07-13):**

| Decision | Choice |
|---|---|
| First trustless path | **zk-email (signed-document class), not zkTLS** — built on `zkemail.nr` |
| Identity binding | **Bind the credential commitment `C = Poseidon2(s, r)`**, reuse Part-A/Part-B verbatim |
| Proving locus (PoC) | **Local CLI (WSL nargo/bb)** — backend never sees the `.eml`; browser WASM later |
| Vendor stance | **Two-track**: trustless zk-email vendor-free; a zkTLS vendor only for login-session facts |

---

## 0. The one reframe everything follows from

The prompt for this work said "ideally via zkTLS." **For the anchor case that is backwards, and
the reason why is the core of the framework.** TLS has no non-repudiation — the server never
signs the data — so *every* zkTLS scheme (notary, MPC, proxy) exists to synthesize a witness for
an unsigned transcript, and that witness-trust assumption is permanent: no amount of ZK on top
removes it. A confirmation email, by contrast, is **already signed at the source** (DKIM: an RSA
signature by `lu.ma` over headers + body hash, public key in DNS). Signed-at-source artifacts
need no witness at all; their trust floor is the source's key, and the whole verification can run
inside a circuit and be checked by an EVM contract.

So the evidence-source hierarchy, by achievable trust floor:

```
signed-at-source   (DKIM email, JWT/SD-JWT, signed PDF, passport SOD)  → trustless possible ✅
witnessed-transport (zkTLS: notary / MPC / proxy)                      → witness trust, forever
asserted           (organizer at a desk, any human attestor)           → attestor trust, forever
```

Event attendance almost always has a signed-at-source artifact (the confirmation email), so the
first-class trustless path is **zk-email**. zkTLS remains the right tool for the strictly smaller
set of facts that live *only* behind a login with no signed artifact (a bank balance, a follower
count) — Track 2, §C.

---

# Part A — What makes a fact privately provable (requirements + method)

## A.1 The seven invariants

A fact can enter the claims layer as a *private* claim iff all seven hold. These are the review
checklist for any proposed source; each maps to a locked requirement.

| # | Invariant | Test | Req |
|---|---|---|---|
| **I1 — Anchored** | A party that is trusted *for this fact* already attests it digitally (signature, or witnessed session, or physical presence + attestor). The proof system extracts truth; it never creates it. | "Who already vouches for this, and in what bytes?" | — |
| **I2 — Verifiable authenticity** | The anchor's attestation can be checked mechanically: a signature verifiable in-circuit (T0) or by a contract/attestor (T1). Unsigned screenshots/PDFs-you-typed fail here. | "Can a circuit or contract check the attestation?" | 3 |
| **I3 — Bound** | The proof **cryptographically commits** to a prover-supplied committed value — our credential commitment `C` (or `idc`) — as a *constrained* public input, never a mutable/echoed label. A stolen proof cannot be re-bound. `metadata`-style correlation fails here (the Vouch finding). | "If this proof leaks in a mempool, can a thief use it under their identity?" | 1 |
| **I4 — Content-specific** | The discriminator (WHICH event, WHICH month, WHICH org) is extracted from **signed/notarized bytes only** and matched in-proof against a public input. Never from unsigned context. | "Could 'Rome 2023' evidence satisfy a 'Cannes 2024' check?" | 5 |
| **I5 — Single-use at the evidence level** | A deterministic nullifier derived from the evidence itself (e.g. hash of the DKIM signature) is consumed on-chain, so one artifact mints one credential, ever. | "Can the same email/session mint twice?" | 1 |
| **I6 — Expirable** | The claim carries `expiresAt` per the fact's volatility (attendance ≈ durable; income ≈ 7–30 d; balance ≈ live-check, never a claim). Revocation = lapse (the Phase-3 rule — identities are hidden, you cannot ban by identity). | "How stale can this be before it's a lie?" | 7 |
| **I7 — Sybil-composed** | The fact is an **attribute** claim (accounts ≠ humans). Statements must compose it `allOf: [UNIQUE_HUMAN*, <attribute>]`; it is never a sole gate. Enforced at statement registration, not per-source. | "Does any statement gate on this alone?" | 4 |

**Privacy is the eighth, implicit invariant:** the raw artifact (email, session transcript) is
processed only where it already lives — the user's device. Our backend receives proofs and public
inputs, never data. Anything that ships the artifact to us (the current DKIM spike) is a staging
tier, not an end state.

**Privacy and unlinkability are independent of *persistence* (2026-07-14).** Three separate axes,
often conflated because the Phase-3 machinery delivers all three at once: **persistence** (is the
fact stored for reuse, or proven fresh?) is a *choice*; **privacy** (does the verifier see the raw
data?) is decided by *proving in ZK*; **unlinkability** (can two apps correlate the proof?) is
decided by the *proof's public outputs* (a per-app nullifier `Poseidon(secret, appId, ctx)` → yes).
So a **one-shot** proof that stores nothing can be fully private and unlinkable — indeed *more*
private than a persistent claim, since it leaves no on-chain footprint to correlate. Persistence
earns its cost only for facts that are expensive to re-acquire, reused constantly, backed by
perishable evidence (rotating DKIM keys), or composed across time. Volatile facts (balance,
current employment) must **never** persist — I6. Full treatment + the decide-per-fact rule:
[`AGGREGATED_PROOFS_DESIGN.md` §0.5](AGGREGATED_PROOFS_DESIGN.md).

## A.2 Source taxonomy

Two axes decide the whole integration: **where the trust anchor lives** (rows — this picks the
proof machinery) and **who may read the data** (privacy column — this picks whether ZK is needed
at all).

| Anchor class | Examples | Proof machinery | Best trust tier | Binding mechanism |
|---|---|---|---|---|
| **Signed document** | DKIM email (Luma/Eventbrite/airline), JWT/OIDC id_token, SD-JWT VC, passport SOD | one **evidence circuit per format** (zk-email, zk-JWT), verified by an EVM verifier | **T0 — trustless** | `C` as constrained public input |
| **Login-session (user-private web)** | ticketing-site session, bank portal, employer portal | zkTLS via vendor (vlayer/Vouch, Reclaim, …) | **T1 — witness-trusted** (permanent), on-chain *verifiable* | vendor-dependent: vlayer `Prover` input (real) vs signed context (attestor-grade) vs metadata (❌ fails I3) |
| **Public / tokened web** | public attendee list, ICS feed, public API | no user privacy needed → oracle or attestor reads it directly | T1 | trivial (no user secret involved) |
| **On-chain state** | balances, NFT ownership | existing `OnchainReadIssuer` (public) / coprocessor (private, deferred) | T0 | n/a today |
| **Physical world only** | showed up at the desk, verbal agreement | human attestor (`AttestorIssuer`) — **irreducible** | T2 | attestor signs over subject/`C` |

Rule of thumb: **always prefer a row higher in the table.** If a fact has both a confirmation
email and a login page (Luma has both), the email wins — same fact, strictly better trust.

## A.3 The binding ladder (I3, graded)

Requirement 1 in increasing strength — name the rung explicitly for every source:

1. **Correlation** — an echoed label (`metadata`, a webhook field). Worthless under adversarial
   replay. Never acceptable alone. *(Where the Vouch webhook path sits today.)*
2. **Attested binding** — a trusted party signs `(fact, C, nullifier, expiry)` as one message
   (EIP-712). Proof-theft is now impossible; **forgery by the attestor remains possible**.
   Acceptable as a stage (T1) because the blast radius is bounded: a rogue attestor can mint
   false *facts*, but cannot steal or link *identities* (it never learns `s`, and claims still
   hang off `C → idc` privately).
3. **In-proof commitment** — `C` is a public input of the ZK proof itself, constrained in-circuit
   (we additionally constrain its opening, `C = Poseidon2(s, r)`, so the prover of the evidence
   and the owner of the identity are the same party in the same proving session). Nothing to
   trust. This is the end state (T0), and it is what makes claims non-transferable *against*
   the holder's will — cooperative transfer (handing over your `.eml` and your `s`) is
   unpreventable in any credential system and is bounded instead by I7's personhood conjunction.

## A.4 Trust tiers and the staging rule

| Tier | Verification | Binding | Who can cheat, and how |
|---|---|---|---|
| **T0** | evidence circuit verified by an EVM contract | rung 3 | only the source itself (Luma's DKIM key custody) + circuit soundness |
| **T1** | attestor (our backend or a vendor) verifies, then signs an EIP-712 binding | rung 2 | attestor can forge facts (not identities); revoke by disabling the issuer + expiry lapse |
| **T2** | attestor verifies, correlation only | rung 1 | anyone who intercepts a proof; **deprecated** — exists only to describe the current spike |

**Staging rule (per requirement 3):** a source may launch at T1 *only if* its EIP-712 message
already carries the same `(C, claimType, evidenceNullifier, expiresAt)` tuple the T0 circuit will
expose as public inputs. Then the T0 upgrade swaps the verifier, not the data model, and nothing
downstream (trees, Circuit B, RedeemIssuer, Circuit A, apps) notices. T2 is not a launch tier.

## A.5 The onboarding method — any new source, eight steps

1. **Find the anchor** (I1/I2). Walk §A.2 top-down: is there a signed artifact? A login-only
   page? A public feed? Nothing digital → `AttestorIssuer`, stop here.
2. **Locate the discriminator in the signed bytes** (I4). Which field says *which* event/org/
   month, and is it under the signature (DKIM `h=` headers / body hash) or merely displayed?
   Write down the exact byte pattern and its stability (template drift risk).
3. **Pick the tier** (§A.4): T0 if the anchor class supports it and the circuit exists/fits;
   else T1 with the staging-rule tuple.
4. **Define the claim type(s)**: `keccak256("EVENT_ATTENDED_<SLUG>") mod p` — one type per
   discriminator value (per event), matching the existing canonical form. Set expiry policy (I6).
5. **Specify the binding** (I3): T0 → `C` constrained in the evidence circuit; T1 → `C` inside
   the attestor's EIP-712 struct. Plus the evidence nullifier (I5): a deterministic hash of the
   attestation itself (DKIM signature hash; vendor transcript hash).
6. **Wire the adapter** (the one irreducible per-source piece, exactly as PHASE3 §8 prescribes):
   an evidence-verifier contract that checks the proof/attestation, consumes the evidence
   nullifier, and calls `insertCredential(C)` on a per-claim-type `VerifiedHumansTree`. Then two
   config txs: `RedeemIssuer.registerProvider(...)` + `registerClaimType(...)`. **No changes to
   Circuit A/B, ClaimsSMTRegistry, EligibilityGate, or any app.**
7. **Compose the statement** (I7): register/extend statements as
   `allOf: [UNIQUE_HUMAN, <new type>, …]` (Circuit A v1 is allOf-only, `MAX_CLAIMS = 4`).
8. **Operate**: monitor the source's key rotation (DKIM registry updates), template drift
   (re-validate step 2 on a schedule), and expiry/renewal UX.

Cost of source N, like provider N, is O(1): steps 1–3 are analysis, 4–5 are parameters, 6 is one
small contract + one tree deploy + two txs, 7–8 are config/ops. A new *format* (first JWT source,
first zkTLS vendor) additionally costs one evidence circuit or one vendor integration — paid once
per format class, never per fact.

---

# Part B — Concrete design: EVENT_ATTENDED, end to end

## B.1 Target property, in one sentence

Alice proves *"Luma emailed **me** a confirmation for event `evt_cannes2026`"* entirely on her
own machine, and the chain ends up with an opaque leaf `Poseidon2(idc, EVENT_ATTENDED_CANNES2026)`
in the existing `ClaimsSMTRegistry` — while the backend never sees the email, no on-chain record
links the email to `idc`, and the proof is useless to a thief.

```
Alice's device (WSL PoC)                         chain (World Chain Sepolia)
────────────────────────                         ───────────────────────────
.eml  ──▶  Circuit C (zk-email evidence)  ──▶  EmailEvidenceVerifier          (NEW, small)
           binds C = Poseidon2(s, r)             · UltraHonk verify
                                                 · DKIMKeyRegistry check       (NEW, small)
                                                 · event_id match
                                                 · consume email_nullifier
                                                 · credTree.insertCredential(C)   ── Part A
                                                       │ (separate tx, relayer ok)
           Circuit B (existing, unchanged) ──▶  RedeemIssuer (existing)           ── Part B
                                                 └▶ ClaimsSMTRegistry leaf
                                                    Poseidon2(idc, EVENT_ATTENDED_*)
           Circuit A (existing, unchanged) ──▶  EligibilityGate.consume(...)      ── app time
                                                 statement allOf:[UNIQUE_HUMAN,
                                                                  EVENT_ATTENDED_CANNES2026]
```

Everything below the first row is **already deployed and proven live** (OVERVIEW §7). The new
surface is exactly: one evidence circuit + two small contracts + config.

## B.2 Circuit C — email evidence (`email_proof/`, new; built on `zkemail.nr`)

Uses ZK Email's audited Noir library (`zkemail.nr`: `RSAPubkey::verify_dkim_signature`,
`get_body_hash`, partial-SHA gadgets — Consensys Diligence + Veridise audited) rather than
hand-rolled RSA. Same toolchain as Circuits A/B (Noir → bb UltraHonk, keccak oracle flavor →
Solidity verifier), so the WSL workflow and verifier-export path are unchanged.

**Public inputs** (order = contract ABI, matching the existing `bytes32[] pub` convention):

| # | Input | Meaning / on-chain check |
|---|---|---|
| 0 | `dkim_key_hash` | Poseidon hash of the RSA pubkey limbs the proof verified against; contract checks it's an allowed key for the source's domain (`DKIMKeyRegistry`) |
| 1 | `event_id_hash` | commitment to the event discriminator token matched in-circuit (§B.4); contract checks it equals the registered source's value |
| 2 | `email_nullifier` | `Poseidon(sig_limbs…)` — deterministic per email (the DKIM signature is unique per message); contract consumes it once (I5) |
| 3 | `cred_commitment` | **`C = Poseidon2(s, r)` — the binding (I3, rung 3).** Contract passes it to `insertCredential` |

**Private witness:** the padded email header bytes; the DKIM signature limbs; the RSA pubkey
limbs; the discriminator token + its index in the header; `s`, `r`.

**Constraints:**
1. `verify_dkim_signature(header, pubkey, signature)` — the zkemail.nr core (RSA-2048/SHA-256,
   relaxed canonicalization).
2. `dkim_key_hash == Poseidon(pubkey_limbs)` — so the contract, not the circuit, decides which
   keys/domains are trusted (key rotation without re-proving-system changes).
3. Discriminator match: the token bytes appear in a **signed** header region (PoC: the `Subject`
   header; escalation path §B.4), and `event_id_hash == Poseidon(pack(token))`.
4. `email_nullifier == Poseidon(sig_limbs…)` — standard zk-email nullifier construction (the
   signature is a 2048-bit unique-per-email value; hash of it reveals nothing about content).
5. `C == Poseidon2(s, r)` — the opening is constrained (not just Semaphore-style inclusion), so
   the email-prover and the identity-owner are the same proving session. Two Poseidon calls; the
   marginal cost is nil and it strengthens rung 3.

Notably **absent**: the recipient address. The Phase-1 spike derived
`subject = keccak256("luma:" + recipient)` — the trustless path doesn't need the recipient at
all, because binding comes from `C`. One fewer PII extraction than today. (Optional hardening —
prove `To:` matches an address Alice committed to earlier — is deliberately *not* included: it
adds an address-book linkage surface and defends only against cooperative transfer, which I3
cannot prevent anyway; I7 is the real bound.)

**Size/feasibility:** header-only proving (the discriminator lives in signed headers; the body
is represented only by its signed `bh=` hash, which we don't open) keeps the circuit at
RSA-2048 verify + SHA-256 over ~1–2 KB of header (~100 constraints/byte) + a few Poseidons —
well inside what bb proves locally in seconds-to-tens-of-seconds on the existing WSL setup, and
inside browser-WASM reach later (Mach-34 publishes browser benchmarks for exactly this library).
If a future source forces body matching, `zkemail.nr`'s partial-SHA gadget bounds the in-circuit
body segment; that is an escalation per-source (step 2 of the method), not a redesign.

## B.3 New contracts (two, both small) + config

**`DKIMKeyRegistry`** (new, ~ClaimsRegistry-sized). `domain → keyHash → {validFrom, retiredAt}`,
owner-managed (governance multisig), events on every change. This is the T0 design's one honest
trust residue besides Luma itself: **someone must assert what lu.ma's DNS key is.** Mitigations,
in order of increasing effort: multi-party key observation before registering; retiredAt +
acceptance deadlines so a compromised historical key can be cut off; later, DNSSEC-chain proofs
or ZK Email's public registry as a cross-check. Old emails stay provable after rotation because
historical keys stay registered (retired ≠ deleted) — attendance is a historical fact.

**`EmailEvidenceVerifier`** (new — the §A.5-step-6 adapter; deliberately shaped like
`RedeemIssuer`):

```solidity
struct EmailSource {
    bytes32 domain;            // e.g. keccak("lu.ma") — looked up in DKIMKeyRegistry
    uint256 eventIdHash;       // the discriminator commitment this source accepts
    VerifiedHumansTree credTree; // per-claim-type anonymity set (writer = this contract)
    bool enabled;
}
mapping(bytes32 => EmailSource) public sources;      // sourceId => config
mapping(uint256 => bool) public consumedEmailNullifier;

function submitEvidence(bytes32 sourceId, bytes calldata proof, bytes32[] calldata pub) external {
    // pub: [0] dkim_key_hash  [1] event_id_hash  [2] email_nullifier  [3] cred_commitment
    EmailSource memory src = sources[sourceId];             // enabled?
    if (!verifier.verify(proof, pub)) revert ProofInvalid(); // Circuit-C UltraHonk verifier
    if (!dkimKeys.isValidKey(src.domain, pub[0])) revert UnknownDkimKey();
    if (uint256(pub[1]) != src.eventIdHash) revert WrongEvent();   // requirement 5
    if (consumedEmailNullifier[uint256(pub[2])]) revert EmailAlreadyUsed(); // I5
    consumedEmailNullifier[uint256(pub[2])] = true;
    src.credTree.insertCredential(pub[3]);                  // Part A — binds C on-chain
}
```

Permissionless (`submitEvidence` by anyone — a relayer is fine, the proof binds `C`, so
front-running is useless and the submitting wallet needn't be Alice's). Keyless-backend
convention holds: the backend only assembles calldata.

**Everything else is existing machinery, untouched:**

| Step | Contract / circuit | Change |
|---|---|---|
| Part A insert | `VerifiedHumansTree` (one new *instance* per event claim type, depth = 20 = `TREE_DEPTH`) | deploy-only, writer = `EmailEvidenceVerifier` |
| Part B redeem | `issuance_proof/` Circuit B + `RedeemIssuer` | **none** — `registerProvider(keccak("luma:evt_cannes2026"), credTree, EVENT_ATTENDED_CANNES2026, LUMA_ISSUER_ID)` is config |
| Claim spine | `ClaimsSMTRegistry` | **none** |
| App time | `eligibility_proof/` Circuit A + `EligibilityGate` + `StatementRegistry` | **none** — register `allOf:[UNIQUE_HUMAN, EVENT_ATTENDED_CANNES2026]` |

One **optional** tweak worth flagging (not required for the PoC): `RedeemIssuer.maxValidity` is
global (default 180 d), but attendance is durable — either accept 180-day renewable attendance
claims (re-redeem is cheap: same credential, but note `redeem_nullifier = Poseidon2(r,
claimType)` is one-shot per type, so renewal needs `updateClaimLeaf` via a renewal path — v2), or
add a per-provider `maxValidity` override to `RedeemIssuer`. Recommend the override (three
lines) whenever Phase-3 contracts are next touched; PoC lives fine with 180 d.

## B.4 Content specificity — distinguishing Cannes 2024 from Rome 2023 (req 5)

The discriminator is a **machine-stable token in signed bytes**, committed as `event_id_hash`,
checked in-circuit (constraint 3) and pinned on-chain (`sources[sourceId].eventIdHash`). Three
grades, chosen per source at onboarding step 2:

1. **Token in a signed header** (PoC): Luma subjects carry the event name; better, Luma's
   `X-Luma-Event-Id`-style headers or the `lu.ma/e/evt-…` token when present in `h=`-covered
   headers. Cheapest circuit (header-only SHA).
2. **Token in the body** (escalation): match `lu.ma/e/evt-xxxxx` inside a bounded body segment
   via partial-SHA. Costs body-segment hashing; use when headers are too loose.
3. **Template hash** (last resort, brittle): commit to a whole known template region. Avoid —
   template drift breaks provers, not security.

Two different events → two `eventIdHash` values → two sources → two claim types → two trees. A
Rome-2023 email cannot satisfy the Cannes source at any layer: the circuit's constraint 3 fails,
and even a (hypothetical) matching token would hit the wrong `sourceId` config on-chain.
**Never-trust-unsigned rule:** constraint 3 only reads header regions covered by the DKIM `h=`
list (the spike's `signedHeaderNames` logic, moved in-circuit — `zkemail.nr` enforces this
structurally by hashing exactly the signed header block). Date bounds, if a source needs them
("registered before the deadline"), come from the signed `Date:` header the same way.

**Residual honesty caveat (fidelity, from the provider note):** we prove *"Luma emailed this
account a message matching the Cannes-2026 discriminator"*. That is ticket *issuance*, not
physical attendance. If organizers need showed-up-in-person, that is a physical-world fact →
`AttestorIssuer` (desk check-in), or a post-event "thanks for attending" email when Luma sends
one — the framework handles either; the claim type name should say which
(`EVENT_TICKET_*` vs `EVENT_ATTENDED_*`).

## B.5 Privacy & unlinkability analysis

- **Backend:** never receives the `.eml`; receives only `(proof, pub)` (PoC: the user proves in
  WSL and pastes/uploads the proof — consistent with the existing prove-locally workflow).
- **Chain, Part A:** reveals `(email_nullifier, C)` together. Luma (or a mailbox provider) knows
  the DKIM signature, can recompute `email_nullifier`, and thus can link *a specific email* → `C`.
  **This is exactly why we bind `C` and not `idc`:** the Part-A/Part-B decoupling (separate tx,
  relayer, timing) breaks the `C → leaf` link inside the per-event anonymity set, and `idc`
  never appears. A sender-side adversary learns "this attendee registered a credential", which
  the act of emailing them already implied.
- **Chain, Part B:** writes an opaque leaf. Anonymity set = attendees of that event who did
  Part A — inherently event-sized (hundreds, not millions). Honest framing: the *semantic*
  content ("some Cannes attendee got a claim") is public by design; what's hidden is *which*
  one, and — via Circuit A's per-app nullifiers — everything at app time, where the set the
  verifier sees is "all eligible humans", not "this event's redeemers".
- **App time:** unchanged Phase-3 guarantees — fresh per-app nullifier, no connector revealed.

**Threats table:**

| Threat | Defense |
|---|---|
| Proof stolen in flight / mempool | `C` is a constrained public input — re-binding requires re-proving, which requires the email + `s` (I3 rung 3) |
| Same email minted twice | `email_nullifier` consumed (I5); double-redeem of one credential blocked by `redeem_nullifier` (existing) |
| Forged/tampered email | DKIM verification in-circuit fails (the spike already demonstrated tamper → reject) |
| Wrong event's email | constraint 3 + on-chain `eventIdHash` pin (req 5) |
| DKIM key compromise at Luma / DNS spoof at registration time | the T0 residue — `DKIMKeyRegistry` governance, key retirement + acceptance deadlines, multi-observation (§B.3) |
| Many accounts, one human (sybil) | not defended here *by design* — I7: statements require `allOf` with `UNIQUE_HUMAN` (one human with N ticket emails still passes only as one human per statement consume) |
| Cooperative transfer (Alice gives Bob everything) | unpreventable in any credential system; bounded by I7 + the fact that giving away `s` gives away one's *entire* identity |
| Same credential redeemed to two identities | impossible — `C` opens to one `s`; two emails → two credentials → two `C`s, but converging on distinct `idc`s only helps a sybil, see I7 |

## B.6 Trust trade-off, stated explicitly (req 3)

| Path | Verifier | Trust set | Binding | Status |
|---|---|---|---|---|
| **T0 (this design)** | Circuit-C UltraHonk verifier on-chain | Luma DKIM key custody + DKIMKeyRegistry governance + circuit soundness (audited lib + our ~50-line composition) | rung 3 (in-proof `C`) | **the end state — and buildable now, vendor-free** |
| T1 stage (optional) | backend verifies DKIM (existing `dkim.js`), signs EIP-712 `{C, claimType, emailNullifier, expiresAt}`; a thin `BoundAttestorIssuer` variant checks the signature and inserts `C` | + our attestor key (can forge facts, cannot steal identities) | rung 2 | worth building **only** if Circuit C slips — the staging rule makes it drop-in-replaceable |
| T2 (current spike) | backend sees the email, correlation subject | + backend sees data (privacy ✗) | rung 1 | deprecated by this doc; keep as demo/reference |

Recommendation: **skip T1 for the email path** — Circuit C is small enough (a composition over
an audited library) that staging buys little; T1's real role is for the *zkTLS* track where the
vendor question is still open.

## B.7 PoC build plan (order, WSL conventions respected)

> **STATUS 2026-07-13: steps 1–5 DONE — proven live on World Chain Sepolia.** Full trustless
> loop: `.eml` → Circuit C (local, zk-email) → `EmailEvidenceVerifier.submitEvidence` (Part A) →
> Circuit-B redeem (`EVENT_ATTENDED_CANNES2026` leaf) → Circuit-A consume (ticket-only statement
> `CANNES_TICKET_ONLY_2026`, nullifier consumed = true). Zero attestor at every step.
> Deployed: DKIMKeyRegistry `0x7E132c95bb1ee268271b6BE44271808072Bd7F66`, EmailEvidenceVerifier
> `0xAFa8818CF321af939a654B22E526ac9551c7c058`, VerifiedHumansTree(luma:evt_cannes2026)
> `0xE857825D3CF47084971728FFA6ed65d10552aCbA`, EmailVerifier (Circuit C)
> `0x798c56E73445918D72e1421737C19A45fF868Aea`.
> Toolchain note: `email_proof/` builds ONLY on nargo 1.0.0-beta.5 + matching bb (zkemail.nr
> v2.0.0's pinned toolchain; poseidon v0.1.0 verified hash-identical to v0.3.0). Two live
> findings: (1) the demo `UNIQUE_HUMAN` claim expired and could not be renewed — the §B.3
> renewal gap is real, spun off as a task; (2) `RootedSMTRegistry.isRootValid` expires even the
> CURRENT root after `rootValidity` — mitigated by config (7 d), fix like Rarimo's
> latest-root-always-valid in v2.

1. `email_proof/` Noir package: import `zkemail.nr`, constraints 1–5, tests deriving public
   inputs from the circuit's own helpers (house style from Circuits A/B). *You run
   `nargo test` / `bb` and paste output.*
2. Extend `make-test-eml.mjs` output as the fixture email (self-signed key → the circuit's
   pubkey witness; token `evt_cannes2026` planted in the Subject) — no real Luma inbox needed,
   same trick as the spike.
3. Export the UltraHonk verifier (keccak flavor), deploy `DKIMKeyRegistry` +
   `EmailEvidenceVerifier` + one `VerifiedHumansTree(depth 20)` on World Chain Sepolia.
4. Config txs: `registerClaimType(EVENT_ATTENDED_CANNES2026)`, `RedeemIssuer.registerProvider`,
   register statement `CANNES_LOUNGE = allOf:[UNIQUE_HUMAN, EVENT_ATTENDED_CANNES2026]`.
5. Live run: prove Circuit C locally → `submitEvidence` → Circuit B redeem → Circuit A
   eligibility → `EligibilityGate.consume`. Exit criterion: the Cannes-lounge worked example
   from the provider note, now with **zero** attestor in the loop.
6. Later (not PoC): browser proving (bb.js/NoirJS — Mach-34's benchmarks say feasible), the
   `RedeemIssuer` per-provider validity override, renewal path.

## B.8 Open questions

- **Luma template ground truth.** Which stable discriminator actually sits in `h=`-signed
  headers of real Luma mail (step-2 analysis needs a real `.eml` corpus; the PoC fixture
  sidesteps it). Same question per future source — it's the method's step 2, always.
- **`zkemail.nr` API surface for our binding pattern** — the library expects consumers to add
  custom outputs post-verification; confirm limb layouts + Poseidon-over-limbs cost when the
  circuit is first assembled.
- **Anonymity-set floor:** should `submitEvidence` optionally batch/delay Part-A inserts to
  avoid a size-1 anonymity set in the first hours of an event source going live? (Same open
  question as PHASE3 §9 bullet 1; inherited, not new.)

---

# Part C — Landscape survey + recommendation

Trust columns state who can forge a fact (beyond the data source itself). "On-chain" means an
EVM contract can verify without trusting our backend. Facts checked against vendor docs
2026-07-13.

| System | Class / mechanism | Trust residue | On-chain verify | Caller-bound value (I3) | Fit notes |
|---|---|---|---|---|---|
| **ZK Email / `zkemail.nr`** | signed-document (DKIM in-circuit), Noir | source's DKIM key + key registry | ✅ native (our own UltraHonk verifier) | ✅ rung 3 — any public input we define | **Track-1 pick.** Same language/toolchain as Circuits A/B; Consensys Diligence + Veridise audits; no vendor, no account, no witness |
| **vlayer** | TLSNotary web proofs + DKIM email proofs, wrapped in RISC Zero zk-receipts; Solidity `Prover` contracts | vlayer notary (TLSNotary single-notary today) + RISC Zero soundness | ✅ (zk receipt) | ✅ rung 3 — we author the `Prover`, so `C` is a real committed input | **Track-2 pick.** The only zkTLS stack where binding is rung-3 without vendor favors |
| **Vouch** | productized vlayer (webhook/SDK) | vlayer's + Vouch's hosted verification | ❌ today (webhook); ✅ *if* they expose the `Prover` (open Q#1/#2 in the provider note) | `metadata` = rung 1 ❌; `Prover` access would make it rung 3 | Keep talks alive as **packaging** for Track 2; their answer to Q#1/#2 decides whether Vouch = vlayer-with-a-catalog or stays T1-only |
| **Reclaim** | proxy-witness (attestors sign claims); large template catalog; many chains | attestor set honesty (proxy model — weakest witness assumption of the group) | ✅ signature-check contracts (attestor-grade, not ZK of the session) | signed `context` field = rung 2 | Solid **T1** fallback with the broadest catalog + chain coverage; never reaches T0 |
| **Opacity** | MPC-TLS notary on an EigenLayer AVS; commit-reveal notary selection; wallet↔account mapping | notary committee + restaking economics | partial (attestations) | app-defined, ~rung 2 | Strongest *economic* story for witnessed transport; heavier integration; overkill for access gating |
| **zkPass** | hybrid — proxy in production, MPC fallback; TransGate extension; 200+ schemas | witness/proxy set | attestation contracts (rung 2-grade) | `uHash`/schema params, ~rung 2 | Catalog-rich, consumer-extension UX; T1 class |
| **Primus (ex-PADO)** | MPC-TLS ("garble-then-prove", QuickSilver IZK); best published MPC performance (≈14× comms) | 2PC attestor | attestation contracts | ~rung 2 | The performance-frontier MPC option; T1 class |
| **TLSNotary** | the base protocol (vlayer/Vouch build on it) | your notary (self-host possible) | ❌ raw (presentations aren't EVM-friendly) | DIY | Not a product; relevant only if we ever self-host a notary |
| **zk coprocessors** | private on-chain facts | prover network | ✅ | varies | out of scope here — already deferred in ARCHITECTURE §3 |

**Recommendation (two-track, as agreed):**

- **Track 1 — build now, vendor-free:** the Part-B design. zk-email covers the anchor use case
  (and airline/hotel/receipt/employment-offer emails — most "attendance-shaped" facts) at T0
  with rung-3 binding, in our own toolchain. No waitlist, no witness, no new trust assumption
  beyond Luma's own key.
- **Track 2 — adopt when a login-only fact actually pays:** **vlayer Web Proofs** is the
  architectural fit (the only zkTLS primitive offering rung-3 binding via self-authored `Prover`
  inputs + on-chain zk receipts), with the permanent, honestly-disclosed notary-trust residue.
  **Vouch remains the preferred packaging** of exactly that primitive *iff* they answer the
  provider note's Q#1/#2 affirmatively (raw `Prover` access + committed caller value); otherwise
  they are a T1 attestor with a catalog, and **Reclaim** is the T1 fallback where coverage
  matters. Do not integrate any of them before a concrete login-only claim has a paying
  consumer — the anti-scope-creep rule applies to vendors too.

---

## Appendix — requirement-by-requirement compliance

| Locked req | Where satisfied |
|---|---|
| 1 Binding | I3 rung 3; Circuit C constraint 5 (`C = Poseidon2(s, r)` as constrained public input); transitively `idc` via the unchanged Circuit B |
| 2 Privacy | proving locus = user device (B.7); backend handles proofs only; T2 explicitly deprecated |
| 3 On-chain, staged honestly | T0 native verifier (B.3); T1 staging rule (A.4) with drop-in upgrade; trade-off table B.6 |
| 4 Sybil | I7; statement `allOf:[UNIQUE_HUMAN, EVENT_ATTENDED_*]`; threats table row |
| 5 Content specificity | I4; Circuit C constraint 3 + on-chain `eventIdHash` pin; signed-bytes-only rule (B.4) |
| 6 Minimal machinery | zero statements-layer circuits; Circuits A/B, RedeemIssuer, ClaimsSMTRegistry, EligibilityGate untouched; new surface = 1 evidence circuit + 2 small contracts + config; tree depth 20 = `TREE_DEPTH` respected |
| 7 Revocation/expiry | I6; expiry-driven (Phase-3 rule); DKIM key retirement for source-side compromise; optional `RedeemIssuer` validity override flagged |
