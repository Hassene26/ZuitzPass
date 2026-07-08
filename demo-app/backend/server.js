// ZuitzPass demo backend — keyless. It manages Alice's identity, proves circuits server-side, and
// returns transaction calldata for the frontend (MetaMask) to sign. It never signs anything.
import express from "express";
import cors from "cors";
import { randomBytes } from "crypto";
import { keccak256, toUtf8Bytes } from "ethers";
import { signRequest } from "@worldcoin/idkit-server";

import { PORT, WORLDID, P, ADDR, PROVIDER_WORLDID } from "./config.js";
import { initPoseidon, derive, toHex32 } from "./poseidon.js";
import { contracts } from "./chain.js";
import { proveCircuit } from "./prove.js";
import { buildIssuanceToml, buildEligibilityToml, credentialHex, claimLeafKeyHex } from "./witness.js";

const app = express();
app.use(cors());
app.use(express.json());

// --- in-memory demo state (single Alice, single-machine demo) ---
let alice = null; // { s, r, claim: { expiresAt, issuerId } | null }
const events = []; // { statementId, name, createdAt, attendees: [nullifier] }

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
  alice = { s: randField(), r: randField(), claim: null };
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

initPoseidon()
  .then(() => app.listen(PORT, () => console.log(`[zuitzpass-demo] backend on :${PORT} (keyless — returns txs for MetaMask)`)))
  .catch((e) => { console.error(e); process.exit(1); });
