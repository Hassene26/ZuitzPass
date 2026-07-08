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
};

export { ADDR };
