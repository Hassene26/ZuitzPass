// Builds each circuit's Prover.toml from Alice's identity + live on-chain Merkle proofs.
// Poseidon comes from poseidon.js (self-tested against the circuits); siblings from the SMT
// contracts' getProof; app_id from the gate's own appScope view (no re-derivation risk).
import { contracts } from "./chain.js";
import { derive, claimTypeField, toHex32 } from "./poseidon.js";

const CLAIM = "UNIQUE_HUMAN";
const kv = (k, v) => `${k} = "${v}"`;
const arr = (name, xs) => `${name} = [${xs.map((x) => `"${x}"`).join(", ")}]`;

export function credentialHex(s, r) {
  return toHex32(derive.commitment(s, r));
}
export function claimLeafKeyHex(s) {
  return toHex32(derive.claimLeafKey(s, claimTypeField(CLAIM)));
}

// Circuit B — issuance/redeem.
export async function buildIssuanceToml(s, r) {
  const ct = claimTypeField(CLAIM);
  const C = toHex32(derive.commitment(s, r));
  const p = await contracts.verifiedHumansTree.getProof(C);
  if (!p.existence) throw new Error("credential not in VerifiedHumansTree — do Part A (insertCredential) first");

  const toml =
    [
      kv("secret", toHex32(s)),
      kv("r", toHex32(r)),
      kv("cred_root", p.root),
      kv("claim_type", toHex32(ct)),
      kv("leaf_key", toHex32(derive.claimLeafKey(s, ct))),
      kv("redeem_nullifier", toHex32(derive.redeemNullifier(r, ct))),
      arr("siblings", p.siblings),
    ].join("\n") + "\n";

  return { toml, credRoot: p.root };
}

// Circuit A — eligibility. `appId` comes from the gate's appScope(app, statementId).
export async function buildEligibilityToml({ s, claim, appId, contextId, nowTs, signal }) {
  const ct = claimTypeField(CLAIM);
  const leafKey = toHex32(derive.claimLeafKey(s, ct));
  const p = await contracts.claimsSmt.getProof(leafKey);
  if (!p.existence) throw new Error("claim not in ClaimsSMTRegistry — redeem first");

  const zeros = Array(20).fill("0x0");
  const nullifier = toHex32(derive.appNullifier(s, appId, BigInt(contextId)));

  const toml =
    [
      kv("secret", toHex32(s)),
      kv("signal", toHex32(BigInt(signal))),
      kv("root", p.root),
      kv("nullifier", nullifier),
      kv("app_id", toHex32(appId)),
      kv("context_id", toHex32(BigInt(contextId))),
      `now_ts = ${nowTs}`,
      arr("claim_types", [toHex32(ct), "0x0", "0x0", "0x0"]),
      arr("issuer_ids", [toHex32(BigInt(claim.issuerId)), "0x0", "0x0", "0x0"]),
      `expires_ats = [${claim.expiresAt}, 0, 0, 0]`,
      "siblings = [",
      "  [" + p.siblings.map((x) => `"${x}"`).join(", ") + "],",
      "  [" + zeros.map((x) => `"${x}"`).join(", ") + "],",
      "  [" + zeros.map((x) => `"${x}"`).join(", ") + "],",
      "  [" + zeros.map((x) => `"${x}"`).join(", ") + "]",
      "]",
    ].join("\n") + "\n";

  return { toml, nullifier };
}
