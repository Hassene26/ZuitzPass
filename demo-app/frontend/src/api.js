// Backend calls (proxied to :8787 by vite).
async function post(path, body) {
  const r = await fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body || {}),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || `${path} failed`);
  return j;
}
async function get(path) {
  const r = await fetch(path);
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || `${path} failed`);
  return j;
}

export const api = {
  rpSignature: (action) => post("/api/rp-signature", { action }),
  aliceState: () => get("/api/alice/state"),
  registerAlice: () => post("/api/alice/register"),
  insertCredentialTx: () => post("/api/alice/insert-credential-tx"),
  redeem: () => post("/api/alice/redeem"),
  createEvent: (name) => post("/api/bob/create-event", { name }),
  events: () => get("/api/events"),
  join: (statementId, appAddress) => post("/api/alice/join", { statementId, appAddress }),
  // Multi-document evidence — verify a batch of .eml, evaluate the statement proven.
  verifyEmails: (files) => post("/api/evidence/verify-emails", { files }),
  validate: () => get("/api/evidence/validate"),
  // Cross-type (human + events): World ID proof + browser email proofs, one tx.
  humanParams: (caller) => post("/api/human/params", { caller }),
  humanPresentTx: (wid, proofs, pubs) => post("/api/human/present-tx", { wid, proofs, pubs }),
  humanPresented: (context, nullifier) => get(`/api/human/presented/${context}/${nullifier}`),
  // Composition (multi-event): prove each email in the browser, present them together.
  composeParams: (caller) => post("/api/compose/params", { caller }),
  composePresentTx: (proofs, pubs) => post("/api/compose/present-tx", { proofs, pubs }),
  composePresented: (nullifier) => get(`/api/compose/presented/${nullifier}`),
  // One-shot email presentation (non-persistent: prove locally, present in one tx).
  oneshotParams: (caller) => post("/api/oneshot/params", { caller }),
  oneshotPresentTx: (proof, pub) => post("/api/oneshot/present-tx", { proof, pub }),
  oneshotPresented: (nullifier) => get(`/api/oneshot/presented/${nullifier}`),
  // Real Circuit-C path (trustless, private, unlinkable) — for on-chain sources.
  evidenceSources: () => get("/api/evidence/sources"),
  emailParams: (sourceKey) => post("/api/evidence/email-params", { sourceKey }),
  submitEvidenceTx: (sourceKey, proof, pub) => post("/api/evidence/submit-tx", { sourceKey, proof, pub }),
  redeemEmailTx: (sourceKey) => post("/api/evidence/redeem-email-tx", { sourceKey }),
  // Vouch (zkTLS) — Phase-1 pseudonymous ticket provider.
  vouchStart: (correlationId) => post("/api/vouch/start", { correlationId }),
  vouchVerifyEmail: (emlBase64) => post("/api/vouch/verify-email", { emlBase64 }),
  vouchAttestTx: (subject) => post("/api/vouch/attest-tx", { subject }),
  vouchClaim: (subject) => get(`/api/vouch/claim/${subject}`),
};
