// ZuitzPass demo backend — keyless. It manages Alice's identity, proves circuits server-side, and
// returns transaction calldata for the frontend (MetaMask) to sign. It never signs anything.
import express from "express";
import cors from "cors";
import { randomBytes } from "crypto";
import { keccak256, toUtf8Bytes } from "ethers";
import { signRequest } from "@worldcoin/idkit-server";

import { PORT, WORLDID, P, ADDR, PROVIDER_WORLDID, VOUCH, CLAIM_EVENT_TICKET_LUMA, EVIDENCE_SOURCES, ONESHOT, COMPOSE, HUMAN_EVENT } from "./config.js";
import { initPoseidon, derive, toHex32, claimTypeField } from "./poseidon.js";
import { contracts, credTreeAt } from "./chain.js";
import { proveCircuit } from "./prove.js";
import { buildIssuanceToml, buildIssuanceTomlFor, buildEligibilityToml, credentialHex, claimLeafKeyHex } from "./witness.js";
import { verifyWebhookSignature, parseVouchPayload, vouchSubject } from "./vouch.js";
import { verifyLumaEmail, testResolver, localTestResolver } from "./dkim.js";
import { verifyAndClassify, evaluateStatements, factLabel } from "./evidence.js";

const app = express();
app.use(cors());
// Stash the raw body on req.rawBody so the Vouch webhook can HMAC it, while still JSON-parsing
// every route as before. Limit raised to fit an uploaded .eml (base64).
app.use(express.json({ limit: "8mb", verify: (req, _res, buf) => { req.rawBody = buf; } }));

// --- in-memory demo state (single Alice, single-machine demo) ---
let alice = null; // { s, r, claim: { expiresAt, issuerId } | null }
// Facts proven from uploaded documents this session (claim-type names, e.g. EVENT_TICKET_LUMA).
// UNIQUE_HUMAN is NOT stored here — it's derived from alice.claim (the on-chain humanity flow).
let docFacts = new Set();
const events = []; // { statementId, name, createdAt, attendees: [nullifier] }

// Vouch spike: verified-but-not-yet-issued ticket attestations, keyed by pseudonymous subject.
const vouchTickets = new Map(); // subject -> { requestId, claimType, fact, verifiedAt, issued }
const seenVouchRequestIds = new Set(); // single-use guard (Question #4 for the Vouch team)

const CONTEXT_ID = 1n; // demo epoch
const SIGNAL = 0n;

const randField = () => BigInt("0x" + randomBytes(31).toString("hex")) % P;
const txOf = (contract, addr, fn, args) => ({ to: addr, data: contract.interface.encodeFunctionData(fn, args) });

app.get("/health", (_req, res) => res.json({ ok: true }));

app.get("/api/alice/state", (_req, res) => {
  if (!alice) return res.json({ registered: false });
  const s = alice.s;
  res.json({
    registered: true,
    idc: toHex32(derive.idc(s)),
    credential: credentialHex(s, alice.r),
    claimLeafKey: claimLeafKeyHex(s),
    hasClaim: !!alice.claim,
  });
});

// World ID v4 RP signature (the client's IDKit widget calls this).
app.post("/api/rp-signature", (req, res) => {
  try {
    if (!WORLDID.signingKey) throw new Error("RP_SIGNING_KEY not set");
    const sig = signRequest({ signingKeyHex: WORLDID.signingKey, action: req.body?.action || WORLDID.action });
    res.json({ rp_id: WORLDID.rpId, app_id: WORLDID.appId, ...sig });
  } catch (e) {
    res.status(500).json({ error: String(e?.message || e) });
  }
});

// Alice creates a fresh master identity (server-side for now).
app.post("/api/alice/register", (_req, res) => {
  alice = { s: randField(), r: randField(), claim: null, emailR: {}, emailClaims: {} };
  docFacts = new Set(); // fresh identity -> fresh document facts
  res.json({ idc: toHex32(derive.idc(alice.s)), credential: credentialHex(alice.s, alice.r) });
});

// Part A: returns the insertCredential(C) tx. Frontend signs with the tree writer (deployer) account.
app.post("/api/alice/insert-credential-tx", (_req, res) => {
  try {
    if (!alice) throw new Error("register first");
    const C = credentialHex(alice.s, alice.r);
    res.json({ tx: txOf(contracts.verifiedHumansTree, ADDR.verifiedHumansTree, "insertCredential", [C]), credential: C });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// Part B: prove Circuit B against the on-chain VerifiedHumansTree, return the redeem tx.
app.post("/api/alice/redeem", async (req, res) => {
  try {
    if (!alice) throw new Error("register first");
    const { toml } = await buildIssuanceToml(alice.s, alice.r); // throws if credential not inserted
    const { proofHex, publicInputs } = await proveCircuit("issuance_proof", toml);

    const expiresAt = Math.floor(Date.now() / 1000) + 90 * 24 * 3600;
    alice.claim = { expiresAt, issuerId: 1 };

    const tx = txOf(contracts.redeemIssuer, ADDR.redeemIssuer, "redeem", [
      PROVIDER_WORLDID, expiresAt, proofHex, publicInputs,
    ]);
    res.json({ tx, providerId: PROVIDER_WORLDID, expiresAt, proof: proofHex, publicInputs });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// Bob: returns a registerStatement tx for a "be a human" event; tracks it optimistically.
app.post("/api/bob/create-event", (req, res) => {
  try {
    const name = (req.body?.name || "Untitled event").toString();
    const statementId = keccak256(toUtf8Bytes(`event:${name}:${Date.now()}`));
    const allOf = [keccak256(toUtf8Bytes("UNIQUE_HUMAN"))];
    const tx = txOf(contracts.statementRegistry, ADDR.statementRegistry, "registerStatement", [
      statementId, { allOf, anyOf: [], consumable: true, metadataURI: `demo:event:${name}` },
    ]);
    events.push({ statementId, name, createdAt: Date.now(), attendees: [] });
    res.json({ tx, statementId, name });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

app.get("/api/events", (_req, res) => res.json({ events }));

// Alice joins an event: prove Circuit A (scoped to her MetaMask address), return the consume tx.
app.post("/api/alice/join", async (req, res) => {
  try {
    if (!alice?.claim) throw new Error("redeem a claim first");
    const { statementId, appAddress } = req.body || {};
    if (!statementId || !appAddress) throw new Error("statementId and appAddress required");

    const appId = await contracts.eligibilityGate.appScope(appAddress, statementId); // bigint
    const nowTs = Math.floor(Date.now() / 1000);

    const { toml, nullifier } = await buildEligibilityToml({
      s: alice.s, claim: alice.claim, appId, contextId: CONTEXT_ID, nowTs, signal: SIGNAL,
    });
    const { proofHex, publicInputs } = await proveCircuit("eligibility_proof", toml);

    const tx = txOf(contracts.eligibilityGate, ADDR.eligibilityGate, "consume", [
      statementId, CONTEXT_ID, SIGNAL, proofHex, publicInputs,
    ]);

    const ev = events.find((e) => e.statementId.toLowerCase() === statementId.toLowerCase());
    if (ev && !ev.attendees.includes(nullifier)) ev.attendees.push(nullifier);

    res.json({ tx, nullifier, contextId: CONTEXT_ID.toString(), signal: SIGNAL.toString(), proof: proofHex, publicInputs });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// =====================================================================================
// Multi-document evidence — "throw a bunch of .eml, click validate, see your statement."
// Real DKIM verification (evidence.js), server-side (Phase-1 fast lane). See
// docs/AGGREGATED_PROOFS_DESIGN.md. Humanity comes from the World ID flow (alice.claim);
// attribute facts come from the emails. Validate evaluates registered statements.
// =====================================================================================

// The full proven-fact set: UNIQUE_HUMAN (iff humanity redeemed) + document facts.
function provenSet() {
  const set = new Set(docFacts);
  if (alice?.claim) set.add("UNIQUE_HUMAN");
  return set;
}

// Verify a batch of uploaded .eml files. Each is DKIM-checked and classified into a fact;
// successes are accumulated. Returns a per-file result list + the running proven-fact set.
app.post("/api/evidence/verify-emails", async (req, res) => {
  try {
    const files = req.body?.files; // [{ name, emlBase64 }]
    if (!Array.isArray(files) || files.length === 0) throw new Error("files[] required");

    const results = [];
    for (const f of files) {
      const eml = Buffer.from(f.emlBase64 || "", "base64");
      // REAL DNS — no test-key override. Real emails (e.g. Luma via Amazon SES) verify against
      // the sender's live DKIM key; self-signed samples no longer pass.
      const r = await verifyAndClassify(eml, {});
      if (r.ok) docFacts.add(r.claimType);
      results.push({ name: f.name || "(file)", ...r });
    }

    res.json({
      results,
      proven: [...provenSet()].map((ct) => ({ claimType: ct, label: factLabel(ct) })),
      humanity: !!alice?.claim,
    });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// =====================================================================================
// REAL Circuit-C path (docs/EMAIL_EVIDENCE_WALKTHROUGH.md) — the trustless, private,
// non-transferable version, for sources deployed on-chain (EVIDENCE_SOURCES). Fixes the
// fast-lane's 3 gaps: the proof BINDS the identity (C), CONSUMES a single-use email
// nullifier on-chain, and the .eml never reaches the backend (Circuit C is proven off-box).
//
// Split of trust: Circuit C touches the email -> proven OFF the backend (locally / in-browser),
// so the email stays private. Circuit B touches NO email data (only secret + the on-chain tree)
// -> proven server-side, exactly like the humanity flow.
// =====================================================================================

app.get("/api/evidence/sources", (_req, res) => {
  res.json({
    sources: Object.entries(EVIDENCE_SOURCES).map(([key, s]) => ({
      key, sourceId: s.sourceId, token: s.token, claimTypeName: s.claimTypeName, label: s.label,
    })),
  });
});

// Step C-0: the params the user needs to prove Circuit C LOCALLY over their own .eml. The email
// never comes here — the backend only supplies the identity binding (master secret + a per-source
// blinding r) and the event token. `secret`/`r` are demo-custodied here; in production they live
// on the user's device.
app.post("/api/evidence/email-params", (req, res) => {
  try {
    if (!alice) throw new Error("register first");
    const src = EVIDENCE_SOURCES[req.body?.sourceKey];
    if (!src) throw new Error("unknown evidence source");
    if (!alice.emailR[src.sourceId]) alice.emailR[src.sourceId] = randField(); // fresh blinding per source
    const r = alice.emailR[src.sourceId];
    res.json({
      sourceKey: req.body.sourceKey,
      sourceId: src.sourceId,
      token: src.token,
      claimTypeName: src.claimTypeName,
      secret: toHex32(alice.s), // demo: device-custodied in production
      r: toHex32(r),
      expectedCredential: toHex32(derive.commitment(alice.s, r)), // C the local proof must output
      note: "Prove Circuit C locally: node make-email-proof-inputs.mjs <your.eml> " + src.token + " <secret> <r>, then nargo execute && bb prove.",
    });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// Step C-1 (Part A): return submitEvidence calldata from the LOCALLY-generated Circuit-C proof.
// `pub` = [keyHash0, keyHash1, event_id, email_nullifier, cred_commitment]. The backend checks the
// proof's C matches this identity's expected credential (so a proof for another identity can't be
// submitted here) and the event_id's source, then hands MetaMask the tx. No email involved.
app.post("/api/evidence/submit-tx", (req, res) => {
  try {
    if (!alice) throw new Error("register first");
    const { sourceKey, proof, pub } = req.body || {};
    const src = EVIDENCE_SOURCES[sourceKey];
    if (!src) throw new Error("unknown evidence source");
    if (!proof || !Array.isArray(pub) || pub.length !== 5) throw new Error("proof + 5 public inputs required");

    const r = alice.emailR[src.sourceId];
    if (!r) throw new Error("call /email-params first (no blinding for this source)");
    const expectedC = toHex32(derive.commitment(alice.s, r));
    if (pub[4].toLowerCase() !== expectedC.toLowerCase()) {
      throw new Error("proof's cred_commitment doesn't match your identity — did you prove with the params from /email-params?");
    }

    const tx = txOf(contracts.emailEvidenceVerifier, ADDR.emailEvidenceVerifier, "submitEvidence", [src.sourceId, proof, pub]);
    res.json({ tx, sourceId: src.sourceId, credential: expectedC });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// Step C-2 (Part B): prove Circuit B server-side (no email) and return redeem calldata. Reads the
// source's credential tree for C; mints EVENT_ATTENDED_* onto the master identity.
app.post("/api/evidence/redeem-email-tx", async (req, res) => {
  try {
    if (!alice) throw new Error("register first");
    const src = EVIDENCE_SOURCES[req.body?.sourceKey];
    if (!src) throw new Error("unknown evidence source");
    const r = alice.emailR[src.sourceId];
    if (!r) throw new Error("submit the evidence first");

    const credTree = credTreeAt(src.credTree);
    const { toml } = await buildIssuanceTomlFor({ s: alice.s, r, claimTypeName: src.claimTypeName, credTree });
    const { proofHex, publicInputs } = await proveCircuit("issuance_proof", toml);

    const expiresAt = Math.floor(Date.now() / 1000) + src.maxValidity;
    alice.emailClaims[src.claimTypeName] = { expiresAt, issuerId: src.issuerId };

    const tx = txOf(contracts.redeemIssuer, ADDR.redeemIssuer, "redeem", [src.sourceId, expiresAt, proofHex, publicInputs]);
    res.json({ tx, claimTypeName: src.claimTypeName, expiresAt });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// =====================================================================================
// ONE-SHOT email presentation (docs/AGGREGATED_PROOFS_DESIGN.md §0.5) — the non-persistent
// path. A real Luma email is proven LOCALLY (email never reaches the backend), then presented
// to OneShotEmailGate in ONE tx: verify -> event pinned -> nullifier consumed. No claim, no tree,
// no redeem. The backend only supplies proving params + assembles the present() calldata.
// =====================================================================================

// Params the user needs to prove the one-shot circuit LOCALLY over their own .eml. Only `secret`
// is demo-custodied here; the email stays on the user's disk.
app.post("/api/oneshot/params", (req, res) => {
  try {
    if (!alice) throw new Error("register first");
    const caller = (req.body?.caller || "").toString();
    if (!caller) throw new Error("caller (your wallet address) required");
    res.json({
      statementId: ONESHOT.statementId,
      contextId: ONESHOT.contextId.toString(),
      eventLabel: ONESHOT.eventLabel,
      secret: toHex32(alice.s),
      caller,
      sampleEml: ONESHOT.sampleEml,
      command: `node make-oneshot-inputs.mjs <path-to>/${ONESHOT.sampleEml} ${toHex32(alice.s)} ${caller} ${ONESHOT.statementId} ${ONESHOT.contextId}`,
    });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// Assemble the present() calldata from the LOCALLY-generated proof. pub =
// [app_id, context_id, key_hash_0, key_hash_1, event_id, nullifier]. No email involved.
app.post("/api/oneshot/present-tx", (req, res) => {
  try {
    const { proof, pub } = req.body || {};
    if (!proof || !Array.isArray(pub) || pub.length !== 6) throw new Error("proof + 6 public inputs required");
    const tx = txOf(contracts.oneShotEmailGate, ADDR.oneShotEmailGate, "present", [
      ONESHOT.statementId, ONESHOT.contextId, proof, pub,
    ]);
    res.json({ tx, nullifier: pub[5], eventLabel: ONESHOT.eventLabel });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// --- CROSS-TYPE (human + events) — World ID personhood + browser email proofs, one tx ----------
app.post("/api/human/params", (req, res) => {
  try {
    if (!alice) throw new Error("register first");
    const caller = (req.body?.caller || "").toString();
    if (!caller) throw new Error("caller (your wallet address) required");
    res.json({
      statementId: HUMAN_EVENT.statementId,
      contextId: HUMAN_EVENT.contextId.toString(),
      label: HUMAN_EVENT.label,
      secret: toHex32(alice.s),
      caller,
      events: HUMAN_EVENT.events,
      gate: ADDR.humanEventGate,
    });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// Assemble the cross-type present() calldata. `wid` = { root, nullifierHash, proof:[8] } from IDKit
// (World ID proof, signal=caller); emailProofs/emailPubs from the browser. No email/PII involved.
app.post("/api/human/present-tx", (req, res) => {
  try {
    const { wid, proofs, pubs } = req.body || {};
    if (!wid?.root || !wid?.nullifierHash || !Array.isArray(wid?.proof) || wid.proof.length !== 8) {
      throw new Error("wid { root, nullifierHash, proof[8] } required");
    }
    if (!Array.isArray(proofs) || !Array.isArray(pubs) || proofs.length !== pubs.length) {
      throw new Error("proofs[] and pubs[] (equal length) required");
    }
    for (const p of pubs) if (!Array.isArray(p) || p.length !== 6) throw new Error("each pub must have 6 fields");
    // Context is authoritative from the email proofs (pub[1]) — the browser picked a fresh one so the
    // same World ID human can re-present in a new instance (one-human-per-(statement,context)).
    const contextId = BigInt(pubs[0][1]);
    const widStruct = { root: wid.root, nullifierHash: wid.nullifierHash, proof: wid.proof };
    const tx = txOf(contracts.humanEventGate, ADDR.humanEventGate, "present", [
      HUMAN_EVENT.statementId, contextId, widStruct, proofs, pubs,
    ]);
    res.json({ tx, humanNullifier: wid.nullifierHash, contextId: contextId.toString(), label: HUMAN_EVENT.label });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

app.get("/api/human/presented/:context/:nullifier", async (req, res) => {
  try {
    const burned = await contracts.humanEventGate.consumedHuman(
      HUMAN_EVENT.statementId, req.params.context, req.params.nullifier
    );
    res.json({ nullifier: req.params.nullifier, presented: burned });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// --- COMPOSITION (multi-event) — all proving in the browser, one presentMany tx --------------
// Params for the compose flow: the statement, its required events (+ sample .eml each), and the
// shared secret. The user's browser proves one Circuit-C proof per event (same secret/app_id/ctx
// -> shared nullifier), then submits them together.
app.post("/api/compose/params", (req, res) => {
  try {
    if (!alice) throw new Error("register first");
    const caller = (req.body?.caller || "").toString();
    if (!caller) throw new Error("caller (your wallet address) required");
    res.json({
      statementId: COMPOSE.statementId,
      contextId: COMPOSE.contextId.toString(),
      label: COMPOSE.label,
      secret: toHex32(alice.s),
      caller,
      events: COMPOSE.events,
      gate: ADDR.multiEventEmailGate,
    });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// Assemble the presentMany calldata from the browser-generated proofs. proofs = [hex,...],
// pubs = [[6 fields], ...]. No email involved (proofs are ZK).
app.post("/api/compose/present-tx", (req, res) => {
  try {
    const { proofs, pubs } = req.body || {};
    if (!Array.isArray(proofs) || !Array.isArray(pubs) || proofs.length !== pubs.length || proofs.length < 2) {
      throw new Error("proofs[] and pubs[] (>=2, equal length) required");
    }
    for (const p of pubs) if (!Array.isArray(p) || p.length !== 6) throw new Error("each pub must have 6 fields");
    const tx = txOf(contracts.multiEventEmailGate, ADDR.multiEventEmailGate, "present", [
      COMPOSE.statementId, COMPOSE.contextId, proofs, pubs,
    ]);
    res.json({ tx, nullifier: pubs[0][5], label: COMPOSE.label });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

app.get("/api/compose/presented/:nullifier", async (req, res) => {
  try {
    const burned = await contracts.multiEventEmailGate.isPresented(req.params.nullifier);
    res.json({ nullifier: req.params.nullifier, presented: burned });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// Browser-proving spike: does a proof verify on-chain against the deployed verifier? (view call —
// the definitive version-match test between @aztec/bb.js and the bb that built the verifier.)
app.post("/api/oneshot/verify-raw", async (req, res) => {
  try {
    const { proof, pub } = req.body || {};
    if (!proof || !Array.isArray(pub)) throw new Error("proof + pub[] required");
    const ok = await contracts.oneShotEmailVerifier.verify(proof, pub);
    res.json({ onChainVerify: ok });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// On-chain truth: has this nullifier been presented (burned)?
app.get("/api/oneshot/presented/:nullifier", async (req, res) => {
  try {
    const burned = await contracts.oneShotEmailGate.isPresented(req.params.nullifier);
    res.json({ nullifier: req.params.nullifier, presented: burned });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// On-chain truth: does this identity hold the source's claim leaf in the ClaimsSMTRegistry?
async function emailClaimOnChain(claimTypeName) {
  if (!alice) return false;
  const leafKey = toHex32(derive.claimLeafKey(alice.s, claimTypeField(claimTypeName)));
  const p = await contracts.claimsSmt.getProof(leafKey);
  return p.existence;
}

// Evaluate which statement(s) the accumulated facts satisfy. Merges: humanity (on-chain claim),
// fast-lane doc facts (server-side DKIM), and REAL-path email claims read from the ClaimsSMTRegistry
// on-chain (the trustworthy source for the Circuit-C path).
app.get("/api/evidence/validate", async (_req, res) => {
  try {
    const proven = provenSet();
    // Fold in on-chain email claims (real path) — the ClaimsSMTRegistry is the source of truth.
    for (const src of Object.values(EVIDENCE_SOURCES)) {
      if (await emailClaimOnChain(src.claimTypeName)) proven.add(src.claimTypeName);
    }
    const { evaluated, best } = evaluateStatements(proven);
    res.json({
      proven: [...proven].map((ct) => ({ claimType: ct, label: factLabel(ct) })),
      humanity: !!alice?.claim,
      statements: evaluated.map((s) => ({
        ...s,
        missing: s.missing.map((ct) => ({ claimType: ct, label: factLabel(ct) })),
      })),
      best,
    });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// =====================================================================================
// Vouch (zkTLS) — Phase-1 pseudonymous ticket provider. See docs/ZKTLS_PROVIDER_NOTE.md.
// Flow: start (client opens Vouch) → webhook (Vouch → us, verify + stash) → attest-tx
// (frontend asks for calldata) → MetaMask signs AttestorIssuer.attest → claim (read back).
// =====================================================================================

// 1) Client asks where to send the user. The real SDK call (getDataSourceUrl) is guarded behind
//    VOUCH_API_KEY; without it we return the mock instructions so the flow is runnable offline.
app.post("/api/vouch/start", (req, res) => {
  const metadata = (req.body?.correlationId || `session:${Date.now()}`).toString();
  if (!VOUCH.apiKey) {
    return res.json({
      mock: true,
      metadata,
      eventId: VOUCH.eventId,
      note: "No VOUCH_API_KEY set — drive the webhook with `node mock-vouch-webhook.mjs` to simulate a completed zkTLS verification.",
    });
  }
  // With a key, this is where you'd call vouch.getDataSourceUrl({ datasourceId, inputs,
  // webhookUrl, redirectBackUrl, metadata }) and return { verificationUrl, requestId }.
  res.json({ mock: false, metadata, eventId: VOUCH.eventId, datasourceId: VOUCH.datasourceId });
});

// 1b) DEV-ONLY: simulate a completed Vouch verification (stands in for the on-device zkTLS flow
//     + webhook) so the frontend button is demoable without a Vouch account. Guarded to mock mode.
app.post("/api/vouch/mock-verify", (req, res) => {
  try {
    if (VOUCH.apiKey) throw new Error("mock-verify disabled when VOUCH_API_KEY is set");
    const handle = (req.body?.handle || "alice.luma").toString();
    const subject = vouchSubject(handle);
    const fact = { handle, eventId: VOUCH.eventId, status: "confirmed", metadata: req.body?.metadata ?? null };
    vouchTickets.set(subject, { requestId: `mock_${Date.now()}`, claimType: CLAIM_EVENT_TICKET_LUMA, fact, verifiedAt: Date.now(), issued: false });
    console.log(`[vouch:mock] verified ticket for ${handle} → subject ${subject}`);
    res.json({ ok: true, subject, claimType: CLAIM_EVENT_TICKET_LUMA, fact });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// 1c) REAL verification: Alice uploads her Luma confirmation .eml (base64). We verify Luma's
//     DKIM signature over it (genuine cryptographic check — forgeries fail), then stash pending.
app.post("/api/vouch/verify-email", async (req, res) => {
  try {
    const emlBase64 = req.body?.emlBase64;
    if (!emlBase64) throw new Error("emlBase64 required (the raw .eml, base64-encoded)");
    const eml = Buffer.from(emlBase64, "base64");

    const cfg = { issuerDomain: VOUCH.issuerDomain, subjectMatch: VOUCH.subjectMatch };
    // Test-DNS override: explicit env wins, else auto-load dkimtest.json, else real DNS.
    const resolver = VOUCH.dkimTest ? testResolver(VOUCH.dkimTest) : localTestResolver();
    const v = await verifyLumaEmail(eml, cfg, resolver ? { resolver } : {});

    // Single-use: dedup on the email's content hash so the same ticket can't mint twice.
    const requestId = keccak256(eml);
    if (seenVouchRequestIds.has(requestId)) {
      return res.status(409).json({ error: "this email was already used" });
    }
    seenVouchRequestIds.add(requestId);
    vouchTickets.set(v.subject, { requestId, claimType: CLAIM_EVENT_TICKET_LUMA, fact: v.fact, verifiedAt: Date.now(), issued: false });
    console.log(`[vouch:dkim] verified ${v.signingDomain} email to ${v.recipient} → subject ${v.subject}`);
    res.json({ ok: true, subject: v.subject, claimType: CLAIM_EVENT_TICKET_LUMA, fact: v.fact, signingDomain: v.signingDomain });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// 2) Vouch POSTs the verified result here. Validate signature → map fact → stash pending.
app.post("/api/vouch/webhook", (req, res) => {
  try {
    const sig = req.get("x-vouch-signature");
    if (!verifyWebhookSignature(req.rawBody, sig, VOUCH.webhookSecret)) {
      return res.status(401).json({ error: "bad signature" });
    }
    const { requestId, subject, claimType, fact } = parseVouchPayload(req.body, {
      eventId: VOUCH.eventId,
      claimType: CLAIM_EVENT_TICKET_LUMA,
    });
    if (seenVouchRequestIds.has(requestId)) {
      return res.status(409).json({ error: "requestId already processed" });
    }
    seenVouchRequestIds.add(requestId);
    vouchTickets.set(subject, { requestId, claimType, fact, verifiedAt: Date.now(), issued: false });
    console.log(`[vouch] verified ticket for ${fact.handle} → subject ${subject}`);
    res.json({ ok: true, subject, claimType });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// 3) Frontend requests the issuance tx. Returns AttestorIssuer.attest calldata for MetaMask
//    (the connected EOA is an allow-listed signer). Backend never signs.
app.post("/api/vouch/attest-tx", (req, res) => {
  try {
    const subject = (req.body?.subject || "").toString();
    const pending = vouchTickets.get(subject);
    if (!pending) throw new Error("no verified Vouch ticket for that subject");
    const tx = txOf(contracts.attestorIssuer, ADDR.attestorIssuer, "attest", [subject, pending.claimType]);
    pending.issued = true; // optimistic; the on-chain read below is the source of truth
    res.json({ tx, subject, claimType: pending.claimType, fact: pending.fact });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

// 4) Read the claim back on-chain (the real source of truth).
app.get("/api/vouch/claim/:subject", async (req, res) => {
  try {
    const subject = req.params.subject;
    const [valid, claim] = await Promise.all([
      contracts.claimsRegistry.hasValidClaim(subject, CLAIM_EVENT_TICKET_LUMA),
      contracts.claimsRegistry.getClaim(subject, CLAIM_EVENT_TICKET_LUMA),
    ]);
    const pending = vouchTickets.get(subject) || null;
    res.json({
      subject,
      claimType: CLAIM_EVENT_TICKET_LUMA,
      hasValidClaim: valid,
      claim: { issuer: claim.issuer, issuedAt: Number(claim.issuedAt), expiresAt: Number(claim.expiresAt) },
      pending: pending ? { fact: pending.fact, verifiedAt: pending.verifiedAt, issued: pending.issued } : null,
    });
  } catch (e) {
    res.status(400).json({ error: String(e?.message || e) });
  }
});

initPoseidon()
  .then(() => app.listen(PORT, () => console.log(`[zuitzpass-demo] backend on :${PORT} (keyless — returns txs for MetaMask)`)))
  .catch((e) => { console.error(e); process.exit(1); });
