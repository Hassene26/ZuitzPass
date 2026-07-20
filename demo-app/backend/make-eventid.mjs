// Compute a Luma email's event_id the SAME way the one-shot circuit does, from a real .eml.
// event_id = Poseidon2(hash_bytes(from_value,128), hash_bytes(event,96)); hash_bytes packs the
// zero-padded buffer into 16-byte LE limbs, folds them Merkle-style, then Poseidon2([fold, len]).
//
//   node make-eventid.mjs <eml>
import { readFileSync } from "fs";
import { verifyDKIMSignature } from "@zk-email/helpers/dist/dkim/index.js";
import { generateEmailVerifierInputsFromDKIMResult } from "@zk-email/zkemail-nr";
import { initPoseidon, poseidon2, toHex32 } from "./poseidon.js";

await initPoseidon();
const emlPath = process.argv[2] || "/Users/hassene/Downloads/safeai.eml";
const eml = readFileSync(emlPath);

const dkim = await verifyDKIMSignature(eml, "amazonses.com", false, true, true);
const inputs = generateEmailVerifierInputsFromDKIMResult(dkim, { maxHeadersLength: 1408, ignoreBodyHashCheck: true });
const ascii = Buffer.from(inputs.header.storage.map(Number).slice(0, Number(inputs.header.len))).toString("binary");

function field(name) {
  const tag = name + ":";
  let index = ascii.startsWith(tag) ? 0 : ascii.indexOf("\r\n" + tag);
  if (index > 0) index += 2;
  const end = ascii.indexOf("\r\n", index);
  return { end, valueStart: index + tag.length };
}
const from = field("from");
const subject = field("subject");
const fromValue = ascii.slice(from.valueStart, from.end);
const subjectValue = ascii.slice(subject.valueStart, subject.end);
const prefixLen = subjectValue.startsWith("Registration confirmed for ") ? 27 : 26;
const eventStr = ascii.slice(subject.valueStart + prefixLen, subject.end);

// hash_bytes: pack N-byte zero-padded buffer -> ceil(N/16) 16-byte LE limbs -> fold -> hash_2([fold,len])
function hashBytes(str, N) {
  const bytes = Array.from(Buffer.from(str, "binary"));
  const buf = bytes.concat(Array(N - bytes.length).fill(0));
  const LIMBS = N / 16;
  const limbs = [];
  for (let l = 0; l < LIMBS; l++) {
    let acc = 0n, mul = 1n;
    for (let j = 0; j < 16; j++) { acc += BigInt(buf[l * 16 + j]) * mul; mul *= 256n; }
    limbs.push(acc);
  }
  let fold = 0n;
  for (const x of limbs) fold = poseidon2(fold, x);
  return poseidon2(fold, BigInt(bytes.length));
}

const eventId = poseidon2(hashBytes(fromValue, 128), hashBytes(eventStr, 96));
console.log(`from : "${fromValue}"`);
console.log(`event: "${eventStr}"`);
console.log(`event_id = ${toHex32(eventId)}`);
