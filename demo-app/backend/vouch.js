// Vouch (zkTLS / vlayer Web Proofs) — Phase-1 pseudonymous provider adapter.
//
// This is the SPIKE surface described in docs/ZKTLS_PROVIDER_NOTE.md ("Phase-1 integration").
// Vouch verifies a Web2 fact on the user's device (e.g. "this Luma account holds a confirmed
// ticket") and POSTs the result to our webhook. We validate it, map it to a claim type +
// pseudonymous subject, and let the frontend issue the claim via AttestorIssuer (MetaMask signs
// — the backend stays keyless).
//
// TRUST (Phase-1): we trust Vouch's verifier + the webhook signature. Trustless on-chain
// verification + idc binding is the parked Phase-3 upgrade (see the note's "Questions for the
// Vouch team"). NONE of the field names / signature scheme below are load-bearing for Phase-3.
//
// ASSUMED, pending Vouch's real schema (Questions #3, #4, #6 in the note):
//   - webhook auth   : HMAC-SHA256(rawBody, VOUCH_WEBHOOK_SECRET), hex, header `x-vouch-signature`
//   - Luma outputs   : { account_handle, event_id, ticket_status: "confirmed" }
//   - single-use     : dedup on `requestId`
// The mock driver (mock-vouch-webhook.mjs) produces exactly this shape so the flow is runnable
// today without a Vouch account. Reconcile with Vouch, then adjust `parseVouchPayload` only.

import { createHmac, timingSafeEqual } from "crypto";
import { keccak256, toUtf8Bytes } from "ethers";

// Pseudonymous subject: stable per verified account, opaque bytes32 (ClaimsRegistry subjects
// are opaque). NOT derived from `metadata` — metadata is client-supplied and unbound, used only
// for request correlation.
export const vouchSubject = (accountHandle) =>
  keccak256(toUtf8Bytes(`vouch:${accountHandle}`));

/// Constant-time verification of the webhook HMAC over the raw request body.
export function verifyWebhookSignature(rawBody, signatureHex, secret) {
  if (!secret) throw new Error("VOUCH_WEBHOOK_SECRET not set");
  if (!signatureHex) throw new Error("missing x-vouch-signature header");
  const expected = createHmac("sha256", secret).update(rawBody).digest();
  let got;
  try {
    got = Buffer.from(String(signatureHex).replace(/^0x/, ""), "hex");
  } catch {
    return false;
  }
  return got.length === expected.length && timingSafeEqual(got, expected);
}

/// Map a verified Vouch webhook payload to { subject, claimType, fact }, or throw if it does not
/// attest the fact we gate on. `cfg` = { eventId, claimType }.
export function parseVouchPayload(payload, cfg) {
  const { requestId, outputs, metadata } = payload || {};
  if (!requestId) throw new Error("payload missing requestId");
  if (!outputs) throw new Error("payload missing outputs");

  const handle = outputs.account_handle;
  const eventId = outputs.event_id;
  const status = outputs.ticket_status;

  if (!handle) throw new Error("outputs missing account_handle");
  if (cfg.eventId && eventId !== cfg.eventId)
    throw new Error(`event_id mismatch: got ${eventId}, gating on ${cfg.eventId}`);
  if (status !== "confirmed")
    throw new Error(`ticket not confirmed (status=${status})`);

  return {
    requestId,
    subject: vouchSubject(handle),
    claimType: cfg.claimType,
    fact: { handle, eventId, status, metadata: metadata ?? null },
  };
}
