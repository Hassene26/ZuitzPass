// Read-only chain access. The backend never signs — it returns tx calldata for MetaMask to sign.
import { JsonRpcProvider, Contract } from "ethers";
import { RPC_URL, ADDR, ABI } from "./config.js";

export const provider = new JsonRpcProvider(RPC_URL);

const c = (addr, abi) => new Contract(addr, abi, provider);

export const contracts = {
  verifiedHumansTree: c(ADDR.verifiedHumansTree, ABI.verifiedHumansTree),
  claimsSmt: c(ADDR.claimsSmt, ABI.claimsSmt),
  redeemIssuer: c(ADDR.redeemIssuer, ABI.redeemIssuer),
  eligibilityGate: c(ADDR.eligibilityGate, ABI.eligibilityGate),
  statementRegistry: c(ADDR.statementRegistry, ABI.statementRegistry),
  emailEvidenceVerifier: c(ADDR.emailEvidenceVerifier, ABI.emailEvidenceVerifier),
  oneShotEmailGate: c(ADDR.oneShotEmailGate, ABI.oneShotEmailGate),
  oneShotEmailVerifier: c(ADDR.oneShotEmailVerifier, ABI.oneShotEmailVerifier),
  multiEventEmailGate: c(ADDR.multiEventEmailGate, ABI.multiEventEmailGate),
  humanEventGate: c(ADDR.humanEventGate, ABI.humanEventGate),
  // Phase-1 pseudonymous layer (Vouch spike)
  attestorIssuer: c(ADDR.attestorIssuer, ABI.attestorIssuer),
  claimsRegistry: c(ADDR.claimsRegistry, ABI.claimsRegistry),
};

// A per-source VerifiedHumansTree (evidence credential tree), built on demand from its address.
export const credTreeAt = (addr) => c(addr, ABI.verifiedHumansTree);

export { ADDR };
