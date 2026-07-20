# READ ME FIRST — ZuitzPass in one sitting

_The front door. Read this, then follow the 5-minute path into the deeper docs. Everything here is
live on **World Chain Sepolia (chainId 4801)**._

---

## The one sentence

> **A real signed email becomes a private zero-knowledge proof — and that proof can either
> *persist* (a reusable on-chain claim) or be *one-shot* (nothing stored), while multiple such
> proofs *compose* into one statement, all proven in the browser so the raw email never leaves the
> device.**

That's the whole system. Everything below unpacks it.

---

## The problem we set out to solve

Real access rules are conjunctions: *"a unique human **AND** attended Cannes 2025 **AND** studied
in Switzerland **AND** paid taxes in 2025."* No single provider or circuit proves all of that. So:

1. **Break every rule into atomic facts.** Each fact is proven by whatever mechanism fits.
2. **Prove facts privately.** The verifier learns the fact, never the underlying data (the email).
3. **Compose facts** into the full statement, without a bespoke circuit per rule.

The insight that makes it tractable: **prove the fact from a source that already signed it.** A
Luma confirmation email is signed by DKIM at the source — so we can verify it inside a ZK circuit
and check it on-chain, with *no* trusted middleman. (This is why we chose **zk-email over zkTLS** —
see the framework doc.)

---

## Three ways to hold a proof

The same email-proof primitive ships in three forms. Choosing between them is a **per-fact
decision** (persistence, privacy, and unlinkability are *independent* axes — the key realization,
detailed in `AGGREGATED_PROOFS_DESIGN.md §0.5`).

```
                        email → ZK proof (Circuit C, in the browser)
                                          │
        ┌─────────────────────────────────┼─────────────────────────────────┐
        ▼                                 ▼                                   ▼
  PERSISTENT                          ONE-SHOT                          (both compose)
  reusable claim                     nothing stored
  ──────────────                     ─────────────
  evidence → redeem →                verify + consume a
  a claim leaf in the                per-app nullifier,
  ClaimsSMTRegistry.                 in ONE transaction.
  Reuse across apps,                 Non-transferable,
  unlinkable. 2 txs.                 unlinkable, 0 stored. 1 tx.
  Good for: durable facts            Good for: "let me in NOW
  reused often; perishable           because I attended X."
  evidence (DKIM keys rotate).
```

**When to use which:** persist only if the fact is expensive to re-acquire (personhood), reused
constantly, or backed by perishable evidence. Otherwise default to **one-shot**. Volatile facts
(a balance) are never stored — checked live.

---

## The composition ladder

Multiple proofs → one statement. Three gates, increasing generality:

| Gate | Statement it proves | How the facts are bound to one person |
|---|---|---|
| **OneShotEmailGate** | "attended event X" | `app_id = appScope(caller, statement)` (caller-bound) |
| **MultiEventEmailGate** | "attended X **AND** Y **AND** …" (up to 8) | a **shared nullifier** `Poseidon(secret, app_id, ctx)` — same secret ⇒ same person, cryptographically |
| **HumanEventGate** | "a **verified human** who attended X…" | **cross-type**: World ID + email proofs bound to the **caller** (two different proof systems can't share a nullifier, so they bind to `msg.sender`) |

The general rule for adding any new provider (Rarimo, zkPassport, a signed PDF, an eID JWT):
**it composes by the shared nullifier if it knows the master secret, otherwise by caller-binding.**

---

## The 5-minute reading path

Read in this order — concept → concrete → composition:

1. **[`docs/PRIVATE_PROVABILITY_FRAMEWORK.md`](docs/PRIVATE_PROVABILITY_FRAMEWORK.md)** — *the why.*
   The 7 invariants a fact must satisfy to be privately provable, trust tiers (T0/T1/T2), the
   binding ladder, and the method to onboard any new source. (Skim Part A; read the invariants
   table.)
2. **[`docs/EMAIL_EVIDENCE_WALKTHROUGH.md`](docs/EMAIL_EVIDENCE_WALKTHROUGH.md)** — *the first
   concrete feature.* DKIM email → ZK proof → on-chain, the pieces, the honest trust boundary, a
   worked example. Standalone — start here if you want the "how" fast.
3. **[`docs/AGGREGATED_PROOFS_DESIGN.md`](docs/AGGREGATED_PROOFS_DESIGN.md)** — *the heart of the
   recent work.* Read **§0.5** (persistence vs one-shot, the three axes, the unifying trick) and
   the **status notes** (they record every live milestone + deployed address).
4. **[`OVERVIEW.md`](OVERVIEW.md)** — *the whole-project map.* Two-layer architecture, both privacy
   modes, contract reference, and **§4.1** (the demo call-by-call sequence).
5. **[`contracts/PHASE3_UNLINKABLE_DESIGN.md`](contracts/PHASE3_UNLINKABLE_DESIGN.md)** — *the
   persistent path in depth* (master identity, Circuit A/B, the claims SMT). Persistence is now
   optional; note the scope banner.

Then read the code — each file has a rich header comment:
- **Circuits:** [`email_oneshot_proof/src/main.nr`](email_oneshot_proof/src/main.nr) (best-commented;
  the real-Luma one-shot circuit) · [`email_proof/src/main.nr`](email_proof/src/main.nr) (persistent).
- **Gates:** [`OneShotEmailGate.sol`](contracts/src/phase3/OneShotEmailGate.sol) ·
  [`MultiEventEmailGate.sol`](contracts/src/phase3/MultiEventEmailGate.sol) ·
  [`HumanEventGate.sol`](contracts/src/phase3/HumanEventGate.sol).
- **Browser proving:** [`demo-app/frontend/src/browserInputs.js`](demo-app/frontend/src/browserInputs.js)
  (DKIM verify + witness build in-browser) · [`browserProve.js`](demo-app/frontend/src/browserProve.js)
  (NoirJS + bb.js).

---

## The demo, step by step

`demo-app/` (keyless backend + MetaMask frontend). Each step is one form above:

| Step | What it shows |
|---|---|
| 1–2 | Create identity + **World ID** personhood (proof generated in-browser via IDKit) |
| 3 | Join an event (Circuit A eligibility over the persistent claims) |
| 4 | Vouch/DKIM ticket (Phase-1 pseudonymous, backend-verified) |
| 5 | **Persistent** email path: evidence → redeem → a reusable claim |
| 6 | **One-shot** email: prove in-browser → one `present()`, nothing stored |
| 7 | **Compose**: attend N events, one person, one tx |
| 8 | **Cross-type**: a verified human who attended X (World ID + email) |

Every transaction logs a clickable **Worldscan** link.

---

## Deployed contracts (World Chain Sepolia, 4801)

The composition stack from this work:

| Contract | Address |
|---|---|
| DKIMKeyRegistry | `0x7E132c95bb1ee268271b6BE44271808072Bd7F66` |
| OneShotEmailVerifier (Circuit C) | `0xf75Bc4576EEE1Fc228993a40394aF5f52c8C86Cf` |
| OneShotEmailGate | `0x936610F6cE762f20A1c26018c0eBa421B1e2fF6A` |
| MultiEventEmailGate | `0x9D8700FDf097766Aa704f6706050Ed950E8d64D6` |
| HumanEventGate | `0x94C8CF41Baa5D8f5251ACbE35283CB61c6d76EB4` |
| EmailEvidenceVerifier (persistent) | `0xAFa8818CF321af939a654B22E526ac9551c7c058` |
| ClaimsSMTRegistry / EligibilityGate / RedeemIssuer | `0xED95…9283` / `0x8413…6af7` / `0xEa23…ae45` |

Full inventory + verification commands: see the deploy scripts in `contracts/script/` and the run
files in `contracts/broadcast/`.

---

## Honest caveats (the things reality taught us)

- **DKIM keys rotate and die.** Luma's aligned key (`calendar.luma-mail.com`) rotates to empty; the
  surviving signature is **Amazon SES's** (shared) — so the in-circuit `From: @…luma-mail.com` check
  + the `event_id` (which commits to organizer + event) are what actually distinguish events.
- **Key size matters.** Real SES mail is **RSA-1024**; the self-signed samples were 2048 — different
  circuit. (A per-source key-size config is a clean future improvement.)
- **Toolchain split.** The zk-email circuits build only on **nargo 1.0.0-beta.5** + matching bb
  (`bb 0.84.0`); the eligibility/issuance circuits use the newer toolchain. `nargo --version` before
  building. Browser proving uses `@aztec/bb.js@0.84.0` + `@noir-lang/noir_js@1.0.0-beta.5`.
- **Sybil is the point.** `HumanEventGate` reverting on a replay by the same human (one human per
  statement+context) is the security property working, not a bug.
- **Open follow-ups:** the `RedeemIssuer` renewal path and a `getProof` ABI audit are spun-off
  tasks; per-source key-size config and cross-type with more providers are natural next steps.
