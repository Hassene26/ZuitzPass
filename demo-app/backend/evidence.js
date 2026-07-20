// Multi-document evidence: verify a batch of DKIM-signed .eml files, classify each into a fact
// (claim type), and evaluate which registered statement the accumulated facts satisfy.
//
// This is the Phase-1 "fast lane" of the aggregation vision (docs/AGGREGATED_PROOFS_DESIGN.md):
// the DKIM signature check is REAL (forged/edited emails fail), done server-side. The unlinkable
// browser-proving path (Circuit C per email) is the follow-up; here we prove the UX — "throw a
// bunch of signed emails, click validate, see the statement you've proven."

import { dkimVerify } from "mailauth/lib/dkim/verify.js";
import { readFileSync, existsSync } from "fs";
import { fileURLToPath } from "url";

// --- the ruleset: sender domain + subject keyword -> a fact (claim type) -----------------------
// Each rule says "a DKIM-signed email from <domain> whose subject contains <subjectMatch> proves
// <claimType>". Adding a fact = one row here (+ a signed sample from make-evidence-samples.mjs).
export const RULES = [
  { claimType: "EVENT_TICKET_LUMA", label: "Attended Cannes 2026", domain: "lu.ma", subjectMatch: "cannes" },
  { claimType: "STUDIED_SWITZERLAND", label: "Studied in Switzerland", domain: "ethz.ch", subjectMatch: "enrollment" },
  { claimType: "TAXES_PAID_2025", label: "Paid taxes in 2025", domain: "estv.admin.ch", subjectMatch: "tax" },
];

// --- demo statements: boolean formulas over claim types (allOf) --------------------------------
// Mirrors StatementRegistry semantics. UNIQUE_HUMAN comes from the World ID flow, the rest from
// emails — so a statement composes a personhood fact with attribute facts (framework invariant I7).
export const STATEMENTS = [
  // Real Luma confirmation email (any event), verified via real DNS.
  { name: "Luma event attendee", allOf: ["EVENT_ATTENDED_LUMA"] },
  { name: "Verified human Luma attendee", allOf: ["UNIQUE_HUMAN", "EVENT_ATTENDED_LUMA"] },
  // Real Circuit-C path (on-chain claim EVENT_ATTENDED_CANNES2026 + on-chain humanity).
  { name: "Cannes Lounge (trustless, unlinkable)", allOf: ["UNIQUE_HUMAN", "EVENT_ATTENDED_CANNES2026"] },
  // Fast-lane classification demo (server-side DKIM).
  { name: "Cannes Alumni Lounge", allOf: ["UNIQUE_HUMAN", "EVENT_TICKET_LUMA"] },
  { name: "Swiss Scholars Circle", allOf: ["UNIQUE_HUMAN", "STUDIED_SWITZERLAND"] },
  { name: "Swiss Taxpayer Residents", allOf: ["UNIQUE_HUMAN", "TAXES_PAID_2025"] },
  {
    name: "Cannes · Swiss-educated · Taxpayer (full bundle)",
    allOf: ["UNIQUE_HUMAN", "EVENT_TICKET_LUMA", "STUDIED_SWITZERLAND", "TAXES_PAID_2025"],
  },
];

const LABEL = Object.fromEntries([
  ["UNIQUE_HUMAN", "A unique human"],
  ["EVENT_ATTENDED_LUMA", "Attended a Luma event"],
  ["EVENT_ATTENDED_CANNES2026", "Attended Cannes 2026 (on-chain, unlinkable)"],
  ...RULES.map((r) => [r.claimType, r.label]),
]);
export const factLabel = (ct) => LABEL[ct] || ct;

// --- minimal signed-header parsing (only trust what DKIM signed) --------------------------------
function parseHeaders(raw) {
  const text = raw.toString("binary");
  const sep = text.indexOf("\r\n\r\n");
  const block = (sep >= 0 ? text.slice(0, sep) : text).replace(/\r\n[ \t]+/g, " ");
  const map = new Map();
  for (const line of block.split("\r\n")) {
    const i = line.indexOf(":");
    if (i < 0) continue;
    const name = line.slice(0, i).trim().toLowerCase();
    if (!map.has(name)) map.set(name, line.slice(i + 1).trim());
  }
  return map;
}

function signedHeaderNames(raw, domain, selector) {
  const text = raw.toString("binary");
  const sep = text.indexOf("\r\n\r\n");
  const block = (sep >= 0 ? text.slice(0, sep) : text).replace(/\r\n[ \t]+/g, " ");
  for (const line of block.split("\r\n")) {
    if (!/^dkim-signature:/i.test(line)) continue;
    const tags = Object.fromEntries(
      line.slice(line.indexOf(":") + 1).split(";").map((t) => t.trim()).filter(Boolean).map((t) => {
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

// Extract the email address and display name from a `From:`-style header value.
function parseFrom(headerValue) {
  if (!headerValue) return { addr: null, display: null };
  const angle = headerValue.match(/^(.*?)<([^>]+)>/);
  if (angle) {
    const display = angle[1].replace(/^["']|["']$/g, "").trim();
    const addr = angle[2].trim().toLowerCase();
    return { addr, display: display || null };
  }
  const m = headerValue.match(/[^\s<>@]+@[^\s<>@]+/);
  return { addr: m ? m[0].toLowerCase() : null, display: null };
}

// --- verify one email + classify it -------------------------------------------------------------
// Uses REAL DNS (no test-key override). A header value is trustworthy iff SOME passing DKIM
// signature covers it (its name is in that signature's h= list) — so we never trust an unsigned
// From/Subject. Returns:
//   { ok: true,  claimType, label, signingDomain, subject, event?, organizer? }
//   { ok: false, reason }
export async function verifyAndClassify(eml, opts = {}) {
  let results;
  try {
    ({ results } = await dkimVerify(eml, opts.resolver ? { resolver: opts.resolver } : {}));
  } catch (e) {
    return { ok: false, reason: "could not parse this file as an email" };
  }

  const passes = (results || []).filter((r) => r.status?.result === "pass" && r.signingDomain);
  if (passes.length === 0) {
    const seen = (results || []).map((r) => `${r.signingDomain || "?"}:${r.status?.result}`).join(", ") || "none";
    return { ok: false, reason: `no valid DKIM signature (its key may be rotated/revoked, or the file was altered) — saw: ${seen}` };
  }

  const headers = parseHeaders(eml);
  const subjectLine = headers.get("subject") || "";
  const fromLine = headers.get("from") || "";

  // The passing signature(s) that cover a given header (so we can trust that header).
  const coveredBy = (name) => passes.find((p) => signedHeaderNames(eml, p.signingDomain, p.selector).has(name));
  const fromSig = coveredBy("from");
  const subjSig = coveredBy("subject");

  // --- Luma confirmation: From <organizer>@calendar.luma-mail.com + "Registration confirmed for X".
  // Luma sends via Amazon SES; the Luma-aligned key often rotates out, so the surviving passing
  // signature is usually amazonses.com — but it covers From+Subject, and SES only lets a verified
  // domain owner send From that domain, so an SES-signed From @…luma-mail.com attests it's Luma's.
  const { addr: fromAddr, display } = parseFrom(fromLine);
  const fromDomain = fromAddr ? fromAddr.split("@")[1] : null;
  // Luma subject variants: "confirmed" (instant registration) and "approved" (organizer-gated).
  const lumaSub = subjectLine.match(/^\s*Registration (?:confirmed|approved) for\s+(.+?)\s*$/i);
  if (fromSig && subjSig && fromDomain && /(^|\.)luma-mail\.com$/i.test(fromDomain) && lumaSub) {
    const organizerHandle = fromAddr.split("@")[0];
    const event = lumaSub[1];
    return {
      ok: true,
      claimType: "EVENT_ATTENDED_LUMA",
      label: `Attended "${event}"` + (display ? ` — ${display}` : ` — ${organizerHandle}`),
      signingDomain: fromSig.signingDomain, // the attesting signature (often amazonses.com)
      fromDomain,
      organizer: display || organizerHandle,
      organizerHandle,
      event,
      subject: subjectLine,
    };
  }

  // --- static ruleset (self-signed samples / other issuers), matched on the SIGNING domain.
  if (!subjSig) {
    return { ok: false, reason: `signed by ${passes.map((p) => p.signingDomain).join(", ")}, but the subject isn't covered by the signature` };
  }
  for (const rule of RULES) {
    const sig = passes.find((p) => {
      const d = p.signingDomain.toLowerCase();
      return d === rule.domain || d.endsWith("." + rule.domain);
    });
    if (sig && subjectLine.toLowerCase().includes(rule.subjectMatch.toLowerCase())) {
      return { ok: true, claimType: rule.claimType, label: rule.label, signingDomain: sig.signingDomain, subject: subjectLine };
    }
  }
  return {
    ok: false,
    reason: `verified (signed by ${passes.map((p) => p.signingDomain).join(", ")}), but no known fact matches — from "${fromDomain}", subject "${subjectLine}"`,
  };
}

// --- statement evaluation -----------------------------------------------------------------------
// Given the set of proven claim-type names, return each statement's satisfied/missing status,
// plus the "best" (most conjuncts) satisfied statement.
export function evaluateStatements(provenSet) {
  const evaluated = STATEMENTS.map((s) => {
    const missing = s.allOf.filter((ct) => !provenSet.has(ct));
    return { name: s.name, allOf: s.allOf, satisfied: missing.length === 0, missing };
  });
  const best = evaluated
    .filter((s) => s.satisfied)
    .sort((a, b) => b.allOf.length - a.allOf.length)[0] || null;
  return { evaluated, best };
}

// --- multi-key DKIM test resolver (self-signed samples, no real DNS) ----------------------------
// Reads evidence-testkeys.json (array of { domain, selector, pubDerBase64 }) written by
// make-evidence-samples.mjs. Returns null in production (no file) so real DNS is authoritative.
export function loadEvidenceTestResolver() {
  const p = fileURLToPath(new URL("./evidence-testkeys.json", import.meta.url));
  if (!existsSync(p)) return null;
  let keys;
  try {
    keys = JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
  const table = new Map(keys.map((k) => [`${k.selector}._domainkey.${k.domain}`, k.pubDerBase64]));
  return async (qname, type) =>
    type === "TXT" && table.has(qname) ? [[`v=DKIM1; k=rsa; p=${table.get(qname)}`]] : [];
}
