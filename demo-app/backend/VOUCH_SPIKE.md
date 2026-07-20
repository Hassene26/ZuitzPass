# Vouch (zkTLS) — Phase-1 provider spike

A runnable, keyless spike that turns a **real, verified Luma ticket** into an on-chain
`EVENT_TICKET_LUMA` claim, via the existing Phase-1 `AttestorIssuer` → `ClaimsRegistry`.
**No new circuits, no signing key on the backend** (MetaMask signs the `attest` tx). Design
context: [`docs/ZKTLS_PROVIDER_NOTE.md`](../../docs/ZKTLS_PROVIDER_NOTE.md).

**The real check is DKIM.** A Luma confirmation email is already cryptographically signed by
`lu.ma` (DKIM, public key in DNS). Alice uploads the `.eml`; the backend verifies that
signature — a genuine check, forgeries fail — the same mechanism Vouch/zk-email use, minus the
ZK privacy wrapper (the deferred Phase-3 upgrade: move this exact check inside a circuit + bind
`idc`). A `mock-verify` webhook path is also kept for reference/testing.

This is **Phase-1 pseudonymous**: the subject is `keccak256("vouch:<account_handle>")` — stable
per account, so the app sees a consistent handle (not unlinkable; that's the parked Phase-3
upgrade). Vouch attribute claims must be composed *with* a personhood claim in a statement, never
used as a sole gate.

## Pieces

| File | Role |
|---|---|
| `dkim.js` | **real check** — verify Luma's DKIM signature over the uploaded `.eml`, extract fact, derive subject |
| `make-test-eml.mjs` | generate a self-signed sample `.eml` + test DNS key (run the real path with no Luma inbox) |
| `server.js` | routes: `/api/vouch/start`, **`/verify-email`**, `/webhook`, `/mock-verify`, `/attest-tx`, `/claim/:subject` |
| `vouch.js` | webhook HMAC verify + subject derivation (reference zkTLS route) |
| `config.js` | `VOUCH` config (issuer domain, DKIM test key), `CLAIM_EVENT_TICKET_LUMA`, Phase-1 addresses/ABIs |

## Flow (DKIM — what the frontend button does)

```
Alice   ── uploads Luma confirmation .eml ─▶ frontend (reads file → base64)
client  ── POST /api/vouch/verify-email ──▶ backend  (verify lu.ma DKIM sig → stash pending by subject)
client  ── POST /api/vouch/attest-tx ─────▶ backend  (returns AttestorIssuer.attest calldata)
client  ── MetaMask signs the tx ────────▶ chain    (attest → ClaimsRegistry.issue)
client  ── GET  /api/vouch/claim/:subject ▶ backend  (reads hasValidClaim on-chain)
```

`subject = keccak256("luma:" + recipient_email)` (only from DKIM-signed headers). The email's
content hash is the single-use guard (same ticket can't mint twice).

## One-time on-chain setup (owner EOA `0x4F77…A973`)

The claim type must exist and the attestor must be permitted to issue it. The attestor's signer
allowlist already includes the deployer EOA (set in `DeployWorldIDStack.s.sol`), so no `setSigner`
is needed. Run from `contracts/` (or via `cast`, WSL):

```bash
CLAIMS=0x5d74F3a39C465f48d545757e65AcCbe55197765B
ATTESTOR=0x03D8feaf664074A88C0F28596ae4FA79c24Fef7f
# EVENT_TICKET_LUMA = keccak256("EVENT_TICKET_LUMA")
CT=$(cast keccak "EVENT_TICKET_LUMA")

cast send $CLAIMS "registerClaimType(bytes32,string)" $CT "ipfs://claim/event-ticket-luma" \
  --rpc-url $RPC_URL --private-key $OWNER_KEY
cast send $CLAIMS "setIssuer(bytes32,address,bool)" $CT $ATTESTOR true \
  --rpc-url $RPC_URL --private-key $OWNER_KEY
```

(If you ever want a *different* EOA to sign `attest`, also
`cast send $ATTESTOR "setSigner(address,bool)" <eoa> true`.)

## Run the real DKIM demo (no Luma inbox needed)

```bash
# 1. generate a self-signed sample email + test DNS key (writes sample-luma.eml + dkimtest.json)
node make-test-eml.mjs lu.ma alice@example.com
#    the backend AUTO-LOADS dkimtest.json (read per request → no restart, no env juggling).
#    production: no dkimtest.json present → real Luma emails resolve lu.ma's key via DNS.

# 2. backend
npm run dev

# 3. REAL verification: upload the .eml (frontend does this; here via curl)
B64=$(base64 -i sample-luma.eml | tr -d '\n')
curl -s -XPOST localhost:8787/api/vouch/verify-email \
  -H 'content-type: application/json' -d "{\"emlBase64\":\"$B64\"}" | jq
#    → { ok:true, subject, signingDomain:"lu.ma", fact:{recipient,...} }
#    (tamper the email → DKIM fails → 400; re-upload → 409 single-use)

# 4. attest calldata (what the frontend hands MetaMask), then send it
curl -s -XPOST localhost:8787/api/vouch/attest-tx \
  -H 'content-type: application/json' -d '{"subject":"<subject>"}' | jq
cast send <tx.to> <tx.data> --rpc-url $RPC_URL --private-key $OWNER_KEY

# 5. after the tx confirms → hasValidClaim:true
curl -s localhost:8787/api/vouch/claim/<subject> | jq
```

In the **frontend**, Step 4 does 3–5 for you: choose the `.eml`, click **Verify & claim
ticket**, approve the attest in MetaMask.

## What's assumed (reconcile with Vouch — the note's "Questions for the Vouch team")

- **Webhook auth**: HMAC-SHA256(rawBody, secret), hex, header `x-vouch-signature`. (Q about the
  real scheme.)
- **Luma outputs**: `{ account_handle, event_id, ticket_status:"confirmed" }`. (Q#6 — real data
  source schema.) Change only `parseVouchPayload` in `vouch.js` when confirmed.
- **Single-use**: dedup on `requestId`. (Q#4 — the real stable field to dedup on.)
- **`metadata`** is treated as correlation-only and is **not** trusted for the subject (docs say
  it isn't cryptographically bound). Subject comes from the verified `account_handle`.

## Not in this spike (Phase-3 parked)

`idc` binding / trustless on-chain vlayer verification. This spike issues into the **Phase-1
`ClaimsRegistry`** (pseudonymous). Composing `EVENT_TICKET_LUMA` with the unlinkable humanity
claim in one statement is the Phase-3 work gated on Vouch exposing the vlayer `Prover`.
