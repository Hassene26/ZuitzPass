// Mock Vouch webhook driver — simulates a completed zkTLS verification so the Phase-1 spike is
// runnable without a Vouch account. Computes the HMAC exactly as vouch.js expects and POSTs a
// realistic payload to the backend's /api/vouch/webhook.
//
// Usage (backend must be running on PORT):
//   VOUCH_WEBHOOK_SECRET=devsecret node mock-vouch-webhook.mjs [account_handle] [event_id]
//
// It prints the derived pseudonymous subject so you can then:
//   curl -s localhost:8787/api/vouch/claim/<subject>            # before issuance → hasValidClaim:false
//   curl -s -XPOST localhost:8787/api/vouch/attest-tx -H 'content-type: application/json' \
//        -d '{"subject":"<subject>"}'                           # → attest calldata for MetaMask

import { createHmac } from "crypto";
import { keccak256, toUtf8Bytes } from "ethers";

const PORT = process.env.PORT || 8787;
const SECRET = process.env.VOUCH_WEBHOOK_SECRET || "devsecret";
const handle = process.argv[2] || "alice.luma";
const eventId = process.argv[3] || process.env.VOUCH_EVENT_ID || "evt_cannes2026";

const subject = keccak256(toUtf8Bytes(`vouch:${handle}`)); // must match vouch.js vouchSubject()

// Payload shaped like Vouch's "Verifying WebProofs" webhook (outputs/webProofs/metadata).
const payload = {
  requestId: `req_${Date.now()}`,
  dataSourceId: "mock-luma-ticket",
  outputs: { account_handle: handle, event_id: eventId, ticket_status: "confirmed" },
  webProofs: [{ outputs: { event_id: eventId }, presentationJson: { data: "<mock>", version: "1" } }],
  metadata: "session:demo", // correlation only — NOT cryptographically bound (Phase-3 caveat)
};

const body = JSON.stringify(payload);
const signature = createHmac("sha256", SECRET).update(body).digest("hex");

const res = await fetch(`http://localhost:${PORT}/api/vouch/webhook`, {
  method: "POST",
  headers: { "content-type": "application/json", "x-vouch-signature": signature },
  body,
});

const json = await res.json().catch(() => ({}));
console.log(`webhook → ${res.status}`, json);
console.log(`\naccount_handle : ${handle}`);
console.log(`subject        : ${subject}`);
console.log(`\nnext:`);
console.log(`  curl -s localhost:${PORT}/api/vouch/claim/${subject}`);
console.log(`  curl -s -XPOST localhost:${PORT}/api/vouch/attest-tx -H 'content-type: application/json' -d '{"subject":"${subject}"}'`);
