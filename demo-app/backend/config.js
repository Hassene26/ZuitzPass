// Deployed addresses + config for the ZuitzPass demo (World Chain Sepolia, chainId 4801).
// Env is loaded via `node --env-file=.env` (see package.json), no dotenv dependency.

export const RPC_URL = process.env.RPC_URL || "https://worldchain-sepolia.g.alchemy.com/public";
export const RELAYER_KEY = process.env.RELAYER_KEY; // funded dev EOA (owner/writer/relayer)
export const REPO_ROOT = process.env.REPO_ROOT || "../.."; // for shelling to nargo/bb + circuits
export const PORT = process.env.PORT || 8787;

// World ID v4 (reuse the RP backend values from the Developer Portal).
export const WORLDID = {
  appId: process.env.VITE_APP_ID || "",
  rpId: process.env.VITE_RP_ID || "",
  signingKey: process.env.RP_SIGNING_KEY || "",
  action: process.env.VITE_ACTION || "zuitzpass-access",
};

export const ADDR = {
  // Phase-3 unlinkable stack
  claimsSmt: "0xED95aCC61243503144D3C17AC130f3051CE99283",
  eligibilityGate: "0x8413A17eE390a84357ef175c32BC77283D6f6af7",
  eligibilityVerifier: "0xA3459Be47Acf9D1364E49EC2a21734DF3BED2f81",
  redeemIssuer: "0xEa23848413b452F8be43B51D4eB1437C0C62ae45",
  issuanceVerifier: "0x696398AB1a46F265aaF68fc7aC9eE648650038cb",
  verifiedHumansTree: "0xA8Fd0C94a2773aEc344Ab15Eb812E668bF4424f5",
  // Shared statements layer
  statementRegistry: "0x9518201B65b3b9a26a80Cf7605952620C9498001",
  // Phase-1 World ID gate (used to verify Alice's World ID proof in Part A)
  worldIdGate: "0x67188d45F49854e0112dfC7c4c002527fdFF99BC",
};

// providerId for the registered worldid provider in RedeemIssuer.
export const PROVIDER_WORLDID = "0xfd9d940269fec4349b9232989173ce30b9c86c6048f690fe7143217b9f5b5b09";

// BN254 scalar field modulus.
export const P = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

// Minimal ABIs (only what the demo calls).
export const ABI = {
  verifiedHumansTree: [
    "function insertCredential(bytes32 commitment)",
    "function getRoot() view returns (bytes32)",
    "function getProof(bytes32 key) view returns (tuple(bytes32 root, bytes32[] siblings, bytes32 existenceKey, bytes32 existenceValue, bool existence, bytes32 auxKey, bytes32 auxValue, bool auxExistence))",
  ],
  claimsSmt: [
    "function getRoot() view returns (bytes32)",
    "function getProof(bytes32 key) view returns (tuple(bytes32 root, bytes32[] siblings, bytes32 existenceKey, bytes32 existenceValue, bool existence, bytes32 auxKey, bytes32 auxValue, bool auxExistence))",
    "function isRootValid(bytes32 root) view returns (bool)",
  ],
  redeemIssuer: [
    "function redeem(bytes32 providerId, uint64 expiresAt, bytes proof, bytes32[] pub)",
  ],
  eligibilityGate: [
    "function consume(bytes32 statementId, uint256 contextId, uint256 signal, bytes proof, bytes32[] pub)",
    "function appScope(address app, bytes32 statementId) view returns (uint256)",
    "function consumedNullifier(uint256) view returns (bool)",
  ],
  statementRegistry: [
    "function registerStatement(bytes32 statementId, tuple(bytes32[] allOf, bytes32[] anyOf, bool consumable, string metadataURI) s)",
    "function statementRegistered(bytes32) view returns (bool)",
  ],
  worldIdGate: [
    "function verify(address signal, uint256 root, uint256 nullifierHash, uint256[8] proof)",
  ],
};

// Canonical claim type: keccak256("UNIQUE_HUMAN") mod p, as a field element (bigint).
// (Value hex: 0x28c2eef236608509ec93078138b2b9ae971aeecd1e018b1880231789d5402b55)
export const CLAIM_UNIQUE_HUMAN_NAME = "UNIQUE_HUMAN";
