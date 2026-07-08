// Runs the Noir/Barretenberg toolchain to turn a Prover.toml into an on-chain-ready proof.
// Shells out to `nargo` + `bb` (must be on PATH in WSL). Server-side proving.
import { execFile } from "child_process";
import { promisify } from "util";
import { writeFile, readFile } from "fs/promises";
import path from "path";
import { REPO_ROOT } from "./config.js";

const run = promisify(execFile);

// circuitPkg: "issuance_proof" | "eligibility_proof"
export async function proveCircuit(circuitPkg, proverToml) {
  const dir = path.resolve(REPO_ROOT, circuitPkg);
  await writeFile(path.join(dir, "Prover.toml"), proverToml);

  // Witness (writes target/<pkg>.gz), then prove (writes target/proof + target/public_inputs).
  await run("nargo", ["execute"], { cwd: dir, maxBuffer: 1 << 26 });
  await run(
    "bb",
    ["prove", "--scheme", "ultra_honk", "--oracle_hash", "keccak",
     "-b", `target/${circuitPkg}.json`, "-w", `target/${circuitPkg}.gz`, "-o", "target"],
    { cwd: dir, maxBuffer: 1 << 26 }
  );

  const proof = await readFile(path.join(dir, "target", "proof"));
  const proofHex = "0x" + proof.toString("hex");

  // public_inputs: concatenated 32-byte field elements.
  const pubBuf = await readFile(path.join(dir, "target", "public_inputs"));
  const publicInputs = [];
  for (let i = 0; i < pubBuf.length; i += 32) {
    publicInputs.push("0x" + pubBuf.subarray(i, i + 32).toString("hex"));
  }
  return { proofHex, publicInputs };
}
