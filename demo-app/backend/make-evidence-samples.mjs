// Generate a batch of self-signed, DKIM-signed sample emails — one per fact in evidence.js's
// ruleset — so the multi-document demo is runnable with no real inbox. Each gets its own fresh
// RSA key; all keys are written to evidence-testkeys.json, which the backend auto-loads as a
// TEST-ONLY DNS override (real emails resolve real DNS instead).
//
//   node make-evidence-samples.mjs
//     -> writes samples/<claimType>.eml  (drag these into the frontend)
//     -> writes evidence-testkeys.json   (backend reads it per request; no restart)
//
// Includes one UNSIGNED sample so you can see the "not provable" rejection path too.

import { generateKeyPairSync } from "crypto";
import { writeFileSync, mkdirSync } from "fs";
import { fileURLToPath } from "url";
import { dkimSign } from "mailauth/lib/dkim/sign.js";

const dir = fileURLToPath(new URL(".", import.meta.url));
const outDir = dir + "samples/";
mkdirSync(outDir, { recursive: true });

// One signed sample per fact: { file, domain, from, to, subject, body }.
const SAMPLES = [
  {
    file: "cannes-ticket",
    domain: "lu.ma",
    from: "Luma <tickets@lu.ma>",
    subject: "Your ticket to Cannes 2026 is confirmed (evt_cannes2026)",
    body: "Your registration for Cannes 2026 is confirmed. See you there!",
  },
  {
    file: "eth-enrollment",
    domain: "ethz.ch",
    from: "ETH Zurich <registrar@ethz.ch>",
    subject: "Enrollment confirmation — MSc Computer Science, ETH Zurich",
    body: "This confirms your enrollment as a student at ETH Zurich.",
  },
  {
    file: "swiss-tax",
    domain: "estv.admin.ch",
    from: "ESTV <noreply@estv.admin.ch>",
    subject: "Tax assessment 2025 — payment received",
    body: "We confirm receipt of your 2025 tax payment.",
  },
];

const recipient = process.argv[2] || "alice@example.com";
const selector = "test1";
const testKeys = [];

for (const s of SAMPLES) {
  const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const pubDerBase64 = publicKey.export({ type: "spki", format: "der" }).toString("base64");

  const raw = Buffer.from(
    [
      `From: ${s.from}`,
      `To: ${recipient}`,
      `Subject: ${s.subject}`,
      "Date: Fri, 10 Jul 2026 02:00:00 +0000",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=utf-8",
      "",
      s.body,
      "",
    ].join("\r\n")
  );

  const { signatures } = await dkimSign(raw, {
    canonicalization: "relaxed/relaxed",
    headerList: "from:to:subject:date",
    signatureData: [{ signingDomain: s.domain, selector, privateKey: privateKey.export({ type: "pkcs8", format: "pem" }) }],
  });

  writeFileSync(outDir + s.file + ".eml", Buffer.concat([Buffer.from(signatures), raw]));
  testKeys.push({ domain: s.domain, selector, pubDerBase64 });
  console.log(`  signed  samples/${s.file}.eml  (${s.domain})`);
}

// An UNSIGNED email — no DKIM header — to demonstrate the honest "not provable" rejection.
writeFileSync(
  outDir + "unsigned-note.eml",
  Buffer.from(
    [
      "From: Someone <someone@example.org>",
      `To: ${recipient}`,
      "Subject: I promise I attended Cannes 2026",
      "",
      "Trust me, I was there.",
      "",
    ].join("\r\n")
  )
);
console.log("  UNSIGNED samples/unsigned-note.eml  (will be rejected — nothing to verify)");

writeFileSync(dir + "evidence-testkeys.json", JSON.stringify(testKeys, null, 2));
console.log(`\nwrote evidence-testkeys.json (${testKeys.length} test keys — backend auto-loads it)`);
console.log("Drag the files in samples/ into the frontend's document dropzone.");
