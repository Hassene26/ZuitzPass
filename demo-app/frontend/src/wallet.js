// MetaMask via ethers. The demo has one person playing Alice and Bob, so connect the DEPLOYER
// account (it owns the StatementRegistry and is the VerifiedHumansTree writer).
import { BrowserProvider } from "ethers";

const WORLD_CHAIN_SEPOLIA = 4801;

let provider;
let signer;

export async function connectWallet() {
  if (!window.ethereum) throw new Error("MetaMask not found");
  provider = new BrowserProvider(window.ethereum);
  await provider.send("eth_requestAccounts", []);
  const net = await provider.getNetwork();
  if (Number(net.chainId) !== WORLD_CHAIN_SEPOLIA) {
    throw new Error(`Wrong network — switch MetaMask to World Chain Sepolia (chainId ${WORLD_CHAIN_SEPOLIA})`);
  }
  signer = await provider.getSigner();
  return signer.address;
}

export function address() {
  return signer?.address ?? null;
}

// Send a { to, data } tx (from the backend) via MetaMask; wait for it to mine.
export async function sendTx(tx) {
  if (!signer) throw new Error("connect wallet first");
  const sent = await signer.sendTransaction({ to: tx.to, data: tx.data });
  return await sent.wait();
}
