// Poseidon (iden3/circomlib) — MUST match the Noir circuits + on-chain PoseidonT3/T4.
// A self-test on boot checks derived values against the validated fixture; if it fails, the JS
// hash disagrees with the circuits and nothing downstream will verify.
import { buildPoseidon } from "circomlibjs";
import { keccak256, toUtf8Bytes } from "ethers";
import { P } from "./config.js";

let poseidon;

export async function initPoseidon() {
  poseidon = await buildPoseidon();
  selfTest();
}

// Poseidon over field elements (bigints) -> bigint.
export function poseidon2(a, b) {
  return poseidon.F.toObject(poseidon([a, b]));
}
export function poseidon3(a, b, c) {
  return poseidon.F.toObject(poseidon([a, b, c]));
}

// bigint -> 0x-padded 32-byte hex.
export function toHex32(x) {
  return "0x" + x.toString(16).padStart(64, "0");
}

// Canonical claim type field value: keccak256(name) mod p.
export function claimTypeField(name) {
  return BigInt(keccak256(toUtf8Bytes(name))) % P;
}

// --- identity / credential derivations (single source of truth for the whole backend) ---
export const derive = {
  idc: (s) => poseidon2(s, 0n), // Poseidon2(secret, 0)
  commitment: (s, r) => poseidon2(s, r), // C = Poseidon2(secret, r)
  claimLeafKey: (s, ct) => poseidon2(derive.idc(s), ct), // Poseidon2(idc, claimType)
  redeemNullifier: (r, ct) => poseidon2(r, ct), // Poseidon2(r, claimType)
  appNullifier: (s, appId, ctx) => poseidon3(s, appId, ctx), // Poseidon3(secret, app_id, context_id)
};

function selfTest() {
  const SECRET = 424242n;
  const R = 987654321n;
  const ct = claimTypeField("UNIQUE_HUMAN");

  const leafKey = derive.claimLeafKey(SECRET, ct);
  const redeemNull = derive.redeemNullifier(R, ct);

  const EXPECT_LEAF_KEY = "0x11b78f71a0bab649eedaeca3452a18ba3fa4f9ae3bedd9c0060fc014a5fefbef";
  const EXPECT_REDEEM_NULL = "0x23b50ca1169bd5a8363ca6f5ec89b1a8b0fc74c4a3b555a00095f4e45037c08d";

  const ok = toHex32(leafKey) === EXPECT_LEAF_KEY && toHex32(redeemNull) === EXPECT_REDEEM_NULL;
  if (!ok) {
    console.error("[poseidon] SELF-TEST FAILED — JS Poseidon does NOT match the circuits.");
    console.error("  leaf_key        :", toHex32(leafKey), "expected", EXPECT_LEAF_KEY);
    console.error("  redeem_nullifier:", toHex32(redeemNull), "expected", EXPECT_REDEEM_NULL);
    throw new Error("Poseidon mismatch — fix encoding before proceeding.");
  }
  console.log("[poseidon] self-test PASS (matches the validated circuit fixtures).");
}
