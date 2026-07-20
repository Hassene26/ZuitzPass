// Browser-side proving spike (docs/AGGREGATED_PROOFS_DESIGN.md — remove the WSL local-prove step).
//
// Proves the one-shot Circuit C entirely in the browser: NoirJS executes the compiled ACIR to a
// witness, then @aztec/bb.js (UltraHonk, keccak flavor) generates a proof verifiable by the deployed
// OneShotEmailVerifier. Deps are imported dynamically so the app still builds before they're
// installed — install ONLY once the beta.5 `bb --version` is known:
//
//   npm i @noir-lang/noir_js@<match> @aztec/bb.js@<match>
//
// The ACIR must come from `nargo compile` in email_oneshot_proof/ (target/email_oneshot_proof.json),
// copied to frontend/public/email_oneshot_proof.json so it can be fetched.
//
// VERSION MATCH IS LOAD-BEARING: the deployed verifier was built by beta.5's bb, so @aztec/bb.js must
// match that bb version, or the browser proof will be rejected on-chain (even though bb.js's own
// verify passes — a false positive). The only real check is the on-chain present() call.

let _circuit = null;
async function loadCircuit() {
  if (_circuit) return _circuit;
  const res = await fetch("/email_oneshot_proof.json");
  if (!res.ok) throw new Error("email_oneshot_proof.json not found in public/ — run `nargo compile` and copy target/email_oneshot_proof.json there");
  _circuit = await res.json();
  return _circuit;
}

// inputMap: the circuit inputs as a plain object (same fields as Prover.toml, values as strings /
// number-string arrays). See make-oneshot-inputs.mjs for the field set.
export async function proveInBrowser(inputMap, onStage = () => {}) {
  const t0 = performance.now();

  onStage("loading circuit + backends");
  const circuit = await loadCircuit();
  const { Noir } = await import("@noir-lang/noir_js");
  const { UltraHonkBackend } = await import("@aztec/bb.js");

  onStage("generating witness (NoirJS)");
  const noir = new Noir(circuit);
  const { witness } = await noir.execute(inputMap);
  const tWitness = performance.now();

  onStage("proving (bb.js UltraHonk, keccak)");
  const backend = new UltraHonkBackend(circuit.bytecode);
  // keccak oracle flavor -> matches the Solidity verifier exported with --oracle_hash keccak.
  const { proof, publicInputs } = await backend.generateProof(witness, { keccak: true });
  const tProve = performance.now();

  onStage("done");
  return {
    proof, // Uint8Array
    publicInputs, // string[] (hex field elements) in the circuit's public order
    timings: {
      witnessMs: Math.round(tWitness - t0),
      proveMs: Math.round(tProve - tWitness),
      totalMs: Math.round(tProve - t0),
    },
  };
}

// Convenience: proof Uint8Array -> 0x hex for calldata.
export function proofToHex(proof) {
  return "0x" + [...proof].map((b) => b.toString(16).padStart(2, "0")).join("");
}
