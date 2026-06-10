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
