// Convert email_oneshot_proof/Prover.toml -> a NoirJS input object (JSON) for the browser-proving
// spike. Writes frontend/public/oneshot_input.json. Minimal TOML parse for our known shape.
import { readFileSync, writeFileSync } from "fs";
import { fileURLToPath } from "url";

const tomlPath = fileURLToPath(new URL("../../email_oneshot_proof/Prover.toml", import.meta.url));
const t = readFileSync(tomlPath, "utf8");

// Split into the root section and [tables].
const sections = { _root: {} };
let cur = "_root";
for (const raw of t.split("\n")) {
  const line = raw.replace(/#.*$/, "").trim();
  if (!line) continue;
  const sec = line.match(/^\[(.+)\]$/);
  if (sec) { cur = sec[1]; sections[cur] = {}; continue; }
  const kv = line.match(/^(\w+)\s*=\s*(.+)$/);
  if (!kv) continue;
  const [, k, vRaw] = kv;
  let v;
  if (vRaw.startsWith("[")) {
    v = vRaw.replace(/^\[|\]$/g, "").split(",").map((x) => x.trim().replace(/^"|"$/g, "")).filter((x) => x.length);
  } else {
    v = vRaw.trim().replace(/^"|"$/g, "");
  }
  sections[cur][k] = v;
}

const r = sections._root;
const input = {
  header: { storage: sections.header.storage, len: sections.header.len },
  pubkey: { modulus: sections.pubkey.modulus, redc: sections.pubkey.redc },
  signature: r.signature,
  from_sequence: { index: sections.from_sequence.index, length: sections.from_sequence.length },
  subject_sequence: { index: sections.subject_sequence.index, length: sections.subject_sequence.length },
  from_value: r.from_value,
  from_value_len: r.from_value_len,
  luma_at_index: r.luma_at_index,
  event: r.event,
  event_len: r.event_len,
  secret: r.secret,
  app_id: r.app_id,
  context_id: r.context_id,
};

const out = fileURLToPath(new URL("../frontend/public/oneshot_input.json", import.meta.url));
writeFileSync(out, JSON.stringify(input));
console.log(`wrote ${out}`);
console.log(`  header.len=${input.header.len} signature=${input.signature.length} from_value=${input.from_value.length} event=${input.event.length}`);
console.log(`  secret=${input.secret.slice(0, 12)}… app_id=${input.app_id.slice(0, 12)}… context_id=${input.context_id}`);
