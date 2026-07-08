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
};
