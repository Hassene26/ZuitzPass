// Generate a self-signed DKIM test email so the real verification path is runnable without a
// real Luma inbox. It signs a sample confirmation with a fresh RSA key and prints the env vars
// that let the backend verify it (the backend uses them ONLY as a test DNS override).
//
//   node make-test-eml.mjs [issuer_domain] [recipient]
//     → writes sample-luma.eml
//     → prints VOUCH_DKIM_TEST_* env lines to paste into .env
//
// Real production needs none of this: real Luma emails verify against lu.ma's real DNS key.

import { generateKeyPairSync } from "crypto";
import { writeFileSync } from "fs";
import { fileURLToPath } from "url";
import { dkimSign } from "mailauth/lib/dkim/sign.js";

const domain = process.argv[2] || "lu.ma";
const recipient = process.argv[3] || "alice@example.com";
const selector = "test1";
const eventLine = "Cannes 2026";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const pubDerBase64 = publicKey.export({ type: "spki", format: "der" }).toString("base64");

const raw = Buffer.from(
  [
    `From: Luma <tickets@${domain}>`,
    `To: ${recipient}`,
    // The event token lives in the SIGNED subject so Circuit C (email_proof/) can match it
    // header-only; the DKIM-spike path is unaffected (it matches "cannes" case-insensitively).
    `Subject: Your ticket to ${eventLine} is confirmed (evt_cannes2026)`,
    "Date: Fri, 10 Jul 2026 02:00:00 +0000",
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=utf-8",
    "",
    `Hi — your registration for ${eventLine} (evt_cannes2026) is confirmed. See you there!`,
    "",
  ].join("\r\n")
);

const { signatures } = await dkimSign(raw, {
  canonicalization: "relaxed/relaxed",
  headerList: "from:to:subject:date",
  signatureData: [{ signingDomain: domain, selector, privateKey: privateKey.export({ type: "pkcs8", format: "pem" }) }],
});

const dir = fileURLToPath(new URL(".", import.meta.url));
writeFileSync(dir + "sample-luma.eml", Buffer.concat([Buffer.from(signatures), raw]));
// The backend auto-loads this test key (dkim.js localTestResolver) — no env juggling, no restart.
writeFileSync(dir + "dkimtest.json", JSON.stringify({ domain, selector, pubDerBase64 }, null, 2));

console.log("wrote sample-luma.eml + dkimtest.json (DKIM-signed by " + domain + ")\n");
console.log("The backend auto-loads dkimtest.json, so just:");
console.log("  1. (re)start / it's already running — the key is read per request");
console.log("  2. upload sample-luma.eml in the frontend Step 4\n");
console.log("VOUCH_ISSUER_DOMAIN is " + domain + " by default; set VOUCH_ISSUER_DOMAIN to override.");
