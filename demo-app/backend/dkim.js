// Real ticket verification via DKIM — Phase-1, no zkTLS, no external account.
//
// A Luma confirmation email is ALREADY cryptographically signed by Luma's mail domain (DKIM):
// an RSA/Ed25519 signature over the email's headers+body, with the public key published in
// lu.ma's DNS. So we can verify "Luma really issued this ticket email, unaltered" from the .eml
// alone — the exact mechanism Vouch/zk-email use, minus the ZK privacy wrapper (which is the
// deferred Phase-3 upgrade: move this same check inside a circuit + bind idc).
//
// TRUST (Phase-1): we trust the backend's DKIM check + Luma's DNS key. The backend sees the
// email (not private). Privacy/unlinkability is the parked upgrade.

import { dkimVerify } from "mailauth/lib/dkim/verify.js";
import { keccak256, toUtf8Bytes } from "ethers";
import { readFileSync, existsSync } from "fs";
import { fileURLToPath } from "url";

// Pseudonymous subject: stable per recipient, opaque bytes32.
export const lumaSubject = (recipientEmail) =>
  keccak256(toUtf8Bytes(`luma:${recipientEmail.trim().toLowerCase()}`));

// --- minimal, signature-safe header parsing -------------------------------------------------
// We only trust header values that DKIM actually signed (present in the passing signature's h=).
function splitHeaders(raw) {
  const text = raw.toString("binary");
  const sep = text.indexOf("\r\n\r\n");
  const headerBlock = sep >= 0 ? text.slice(0, sep) : text;
  // unfold folded headers (continuation lines start with WSP)
  const unfolded = headerBlock.replace(/\r\n[ \t]+/g, " ");
  const map = new Map(); // lowercased name -> [values...]
  for (const line of unfolded.split("\r\n")) {
    const i = line.indexOf(":");
    if (i < 0) continue;
    const name = line.slice(0, i).trim().toLowerCase();
    const value = line.slice(i + 1).trim();
    if (!map.has(name)) map.set(name, []);
    map.get(name).push(value);
  }
  return map;
}

function firstAddress(headerValue) {
  if (!headerValue) return null;
  const angle = headerValue.match(/<([^>]+)>/);
  const raw = angle ? angle[1] : headerValue.split(",")[0];
  const m = raw.match(/[^\s<>@]+@[^\s<>@]+/);
  return m ? m[0].toLowerCase() : null;
}

// Parse the h= (signed header names) of the DKIM-Signature that matches domain+selector.
function signedHeaderNames(headers, domain, selector) {
  for (const sig of headers.get("dkim-signature") || []) {
    const tags = Object.fromEntries(
      sig.split(";").map((t) => t.trim()).filter(Boolean).map((t) => {
        const j = t.indexOf("=");
        return [t.slice(0, j).trim(), t.slice(j + 1).trim()];
      })
    );
    if (tags.d === domain && tags.s === selector && tags.h) {
      return new Set(tags.h.split(":").map((h) => h.trim().toLowerCase()));
    }
  }
  return new Set();
}

/// Verify a Luma (or configured issuer) confirmation email.
/// @param eml       Buffer of the raw .eml (exact bytes — DKIM is byte-sensitive).
/// @param cfg       { issuerDomain, subjectMatch }.
/// @param opts      { resolver } optional DNS override (used by the self-signed test path).
/// Returns { signingDomain, selector, recipient, subjectLine, subject, fact } or throws.
export async function verifyLumaEmail(eml, cfg, opts = {}) {
  const { results } = await dkimVerify(eml, opts.resolver ? { resolver: opts.resolver } : {});

  // Accept only a PASS from the configured issuer domain.
  const pass = (results || []).find(
    (r) =>
      r.status?.result === "pass" &&
      r.signingDomain &&
      (r.signingDomain === cfg.issuerDomain || r.signingDomain.endsWith("." + cfg.issuerDomain))
  );
  if (!pass) {
    const got = (results || []).map((r) => `${r.signingDomain || "?"}:${r.status?.result}`).join(", ") || "none";
    throw new Error(`no valid DKIM signature from ${cfg.issuerDomain} (got: ${got})`);
  }

  const headers = splitHeaders(eml);
  const signed = signedHeaderNames(headers, pass.signingDomain, pass.selector);

  // Only trust fields DKIM signed.
  if (!signed.has("subject")) throw new Error("subject header not DKIM-signed — cannot trust it");
  if (!signed.has("to")) throw new Error("to header not DKIM-signed — cannot derive a stable subject");

  const subjectLine = (headers.get("subject") || [""])[0];
  const recipient = firstAddress((headers.get("to") || [""])[0]);
  if (!recipient) throw new Error("could not parse recipient address");

  // Assert it's the right ticket (configurable). Empty subjectMatch = skip (verify issuer only).
  if (cfg.subjectMatch && !subjectLine.toLowerCase().includes(cfg.subjectMatch.toLowerCase())) {
    throw new Error(`subject does not match "${cfg.subjectMatch}": ${JSON.stringify(subjectLine)}`);
  }

  return {
    signingDomain: pass.signingDomain,
    selector: pass.selector,
    recipient,
    subjectLine,
    subject: lumaSubject(recipient),
    fact: { issuer: pass.signingDomain, recipient, subject: subjectLine },
  };
}

// Build a DNS resolver that returns a fixed DKIM public key for the self-signed test path.
// Guarded by env in server.js; NEVER used when real DNS should be authoritative.
export function testResolver({ domain, selector, pubDerBase64 }) {
  const name = `${selector}._domainkey.${domain}`;
  return async (qname, type) =>
    type === "TXT" && qname === name ? [[`v=DKIM1; k=rsa; p=${pubDerBase64}`]] : [];
}

// Auto-load a resolver from dkimtest.json if present (written by make-test-eml.mjs), read fresh
// each call so regenerating the sample needs no restart. Returns null in production (no file) →
// real DNS is authoritative.
export function localTestResolver() {
  const p = fileURLToPath(new URL("./dkimtest.json", import.meta.url));
  if (!existsSync(p)) return null;
  try {
    return testResolver(JSON.parse(readFileSync(p, "utf8")));
  } catch {
    return null;
  }
}
