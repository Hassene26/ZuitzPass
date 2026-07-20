// In-browser input generation for the one-shot Circuit C — the last privacy piece: the .eml is
// parsed + DKIM-verified + witness-built entirely in the browser, so it NEVER reaches the backend.
// A faithful port of demo-app/backend/make-oneshot-inputs.mjs. Returns the NoirJS input object.

import { keccak256, AbiCoder } from "ethers";

const P = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const MAX_HEADER_LENGTH = 1408;
const MAX_FROM_LENGTH = 128;
const MAX_EVENT_LENGTH = 96;
const SIGNING_DOMAIN = "amazonses.com"; // the surviving signature on real Luma mail

// Build the circuit input object from a raw .eml string + the caller-scoped params.
// { emlText, secret, caller, statementId, contextId } -> input map (+ some derived fields for UI).
export async function buildOneshotInputs({ emlText, secret, caller, statementId, contextId }) {
  // Lazy-load the zk-email libs (browser-heavy) only when actually proving.
  const { verifyDKIMSignature } = await import("@zk-email/helpers/dist/dkim/index.js");
  const { generateEmailVerifierInputsFromDKIMResult } = await import("@zk-email/zkemail-nr");

  const dkim = await verifyDKIMSignature(emlText, SIGNING_DOMAIN, false, true, true);
  const inputs = generateEmailVerifierInputsFromDKIMResult(dkim, {
    maxHeadersLength: MAX_HEADER_LENGTH,
    ignoreBodyHashCheck: true,
  });

  const headerBytes = inputs.header.storage.map(Number);
  const headerLen = Number(inputs.header.len);
  const ascii = String.fromCharCode(...headerBytes.slice(0, headerLen));

  const field = (name) => {
    const tag = name + ":";
    let index = ascii.startsWith(tag) ? 0 : ascii.indexOf("\r\n" + tag);
    if (index < 0) throw new Error(`'${name}:' not found in the signed header`);
    if (index > 0) index += 2;
    const end = ascii.indexOf("\r\n", index);
    return { index, end: end < 0 ? headerLen : end, valueStart: index + tag.length };
  };

  const from = field("from");
  const subject = field("subject");

  const fromValue = ascii.slice(from.valueStart, from.end);
  const lumaAtIndex = ascii.indexOf("@calendar.luma-mail.com", from.valueStart);
  if (lumaAtIndex < 0 || lumaAtIndex + 23 > from.end) {
    throw new Error(`From is not a @calendar.luma-mail.com address: "${fromValue}"`);
  }

  const subjectValue = ascii.slice(subject.valueStart, subject.end);
  let prefixLen;
  if (subjectValue.startsWith("Registration confirmed for ")) prefixLen = 27;
  else if (subjectValue.startsWith("Registration approved for ")) prefixLen = 26;
  else throw new Error(`Subject is not a Luma registration confirmation: "${subjectValue}"`);
  const eventStart = subject.valueStart + prefixLen;
  const eventStr = ascii.slice(eventStart, subject.end);

  const pad = (str, n) => {
    const b = [...str].map((c) => c.charCodeAt(0));
    if (b.length > n) throw new Error(`"${str}" longer than ${n} bytes`);
    return { buf: b.concat(Array(n - b.length).fill(0)).map(String), len: b.length };
  };
  const fromPacked = pad(fromValue, MAX_FROM_LENGTH);
  const eventPacked = pad(eventStr, MAX_EVENT_LENGTH);

  const appId =
    BigInt(keccak256(AbiCoder.defaultAbiCoder().encode(["address", "bytes32"], [caller, statementId]))) % P;

  const inputMap = {
    header: { storage: inputs.header.storage, len: inputs.header.len },
    pubkey: { modulus: inputs.pubkey.modulus, redc: inputs.pubkey.redc },
    signature: inputs.signature,
    from_sequence: { index: String(from.index), length: String(from.end - from.index) },
    subject_sequence: { index: String(subject.index), length: String(subject.end - subject.index) },
    from_value: fromPacked.buf,
    from_value_len: String(fromPacked.len),
    luma_at_index: String(lumaAtIndex),
    event: eventPacked.buf,
    event_len: String(eventPacked.len),
    secret: String(secret),
    app_id: "0x" + appId.toString(16),
    context_id: String(contextId),
  };

  return { inputMap, fromValue, event: eventStr, appId: "0x" + appId.toString(16) };
}
