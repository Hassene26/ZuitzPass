// Deployed addresses + config for the ZuitzPass demo (World Chain Sepolia, chainId 4801).
// Env is loaded via `node --env-file=.env` (see package.json), no dotenv dependency.
import { keccak256, toUtf8Bytes } from "ethers";

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
  emailEvidenceVerifier: "0xAFa8818CF321af939a654B22E526ac9551c7c058",
  dkimKeyRegistry: "0x7E132c95bb1ee268271b6BE44271808072Bd7F66",
  oneShotEmailGate: "0x936610F6cE762f20A1c26018c0eBa421B1e2fF6A",
  oneShotEmailVerifier: "0xf75Bc4576EEE1Fc228993a40394aF5f52c8C86Cf",
  // MultiEventEmailGate (composition) — deployed on World Chain Sepolia (env override supported).
  multiEventEmailGate: process.env.MULTI_EVENT_GATE || "0x9D8700FDf097766Aa704f6706050Ed950E8d64D6",
  // HumanEventGate (cross-type: World ID + email events) — deployed on World Chain Sepolia.
  humanEventGate: process.env.HUMAN_EVENT_GATE || "0x94C8CF41Baa5D8f5251ACbE35283CB61c6d76EB4",
  eligibilityGate: "0x8413A17eE390a84357ef175c32BC77283D6f6af7",
  eligibilityVerifier: "0xA3459Be47Acf9D1364E49EC2a21734DF3BED2f81",
  redeemIssuer: "0xEa23848413b452F8be43B51D4eB1437C0C62ae45",
  issuanceVerifier: "0x696398AB1a46F265aaF68fc7aC9eE648650038cb",
  verifiedHumansTree: "0xA8Fd0C94a2773aEc344Ab15Eb812E668bF4424f5",
  // Shared statements layer
  statementRegistry: "0x9518201B65b3b9a26a80Cf7605952620C9498001",
  // Phase-1 pseudonymous statements layer (used by the Vouch spike)
  claimsRegistry: "0x5d74F3a39C465f48d545757e65AcCbe55197765B",
  attestorIssuer: "0x03D8feaf664074A88C0F28596ae4FA79c24Fef7f",
  // Phase-1 World ID gate (used to verify Alice's World ID proof in Part A)
  worldIdGate: "0x67188d45F49854e0112dfC7c4c002527fdFF99BC",
};

// Vouch (zkTLS) provider config — Phase-1 pseudonymous. See docs/ZKTLS_PROVIDER_NOTE.md.
export const VOUCH = {
  apiKey: process.env.VOUCH_API_KEY || "", // guarded: /api/vouch/start only calls the real SDK if set
  webhookSecret: process.env.VOUCH_WEBHOOK_SECRET || "",
  datasourceId: process.env.VOUCH_DATASOURCE_ID || "", // the lu.ma ticket data source id
  eventId: process.env.VOUCH_EVENT_ID || "evt_cannes2026", // which Luma event we gate on
  // DKIM email verification (the real Phase-1 check).
  issuerDomain: process.env.VOUCH_ISSUER_DOMAIN || "lu.ma", // email must be DKIM-signed by this domain
  subjectMatch: process.env.VOUCH_SUBJECT_MATCH || "", // require this substring in the Subject (empty = issuer-only)
  // TEST-ONLY DNS override so a self-signed sample email verifies without real DNS.
  // Set by make-test-eml.mjs; leave unset in production (real Luma keys resolve via DNS).
  dkimTest:
    process.env.VOUCH_DKIM_TEST_PUBKEY && process.env.VOUCH_DKIM_TEST_DOMAIN
      ? {
          domain: process.env.VOUCH_DKIM_TEST_DOMAIN,
          selector: process.env.VOUCH_DKIM_TEST_SELECTOR || "test1",
          pubDerBase64: process.env.VOUCH_DKIM_TEST_PUBKEY,
        }
      : null,
};

// providerId for the registered worldid provider in RedeemIssuer.
export const PROVIDER_WORLDID = "0xfd9d940269fec4349b9232989173ce30b9c86c6048f690fe7143217b9f5b5b09";

// Real Circuit-C evidence sources deployed on-chain (docs/EMAIL_EVIDENCE_WALKTHROUGH.md). A source
// = one (issuer domain, event token) feeding one credential tree + RedeemIssuer provider. Only the
// Cannes source is deployed today; adding a doc type = deploy another source stack + a row here.
// `sourceId` doubles as the RedeemIssuer providerId (that's how DeployEmailEvidence wired it).
export const EVIDENCE_SOURCES = {
  "luma:evt_cannes2026": {
    sourceId: "0x2e5733258f69acb9e6228c9b70fc90f08d8551343cce9ca0cb28d971375401ff",
    token: "evt_cannes2026",
    claimTypeName: "EVENT_ATTENDED_CANNES2026",
    credTree: "0xE857825D3CF47084971728FFA6ed65d10552aCbA",
    issuerId: 2,
    label: "Attended Cannes 2026",
    maxValidity: 150 * 24 * 3600, // < RedeemIssuer.maxValidity (180d)
  },
};

// One-shot email presentation (docs/AGGREGATED_PROOFS_DESIGN.md §0.5). A registered statement =
// one on-chain event the OneShotEmailGate accepts a Circuit-C(one-shot) proof for. The demo event
// is Safe AI Lausanne / "Hack your way into LLMs" (statementId = keccak256("LUMA_ATTENDEE")).
export const ONESHOT = {
  statementId: keccak256(toUtf8Bytes("LUMA_ATTENDEE")),
  contextId: 1n,
  eventLabel: 'Attended a Luma event ("Hack your way into LLMs" — Safe AI Lausanne)',
  sampleEml: "safeai.eml", // the .eml whose event_id the deployed statement pins
};

// One-shot COMPOSITION (docs/AGGREGATED_PROOFS_DESIGN.md §0.5 "unifying trick"): a statement
// requiring a SET of events, proven by one Circuit-C proof each, all sharing the nullifier.
export const COMPOSE = {
  statementId: keccak256(toUtf8Bytes("LUMA_ATTENDEE_X_Y_Z")), // 3-event statement (register on-chain)
  contextId: 1n,
  label: "Attended ALL 3 Luma events",
  events: [
    { label: '"Hack your way into LLMs" — Safe AI Lausanne', sampleEml: "safeai.eml", eventId: "0x2b29c740efac19c7d88672bbdaeeae45f2b916faefb5613d5b2849425323be1a" },
    { label: '"Trezor - Hardware Wallet" — BSA EPFL', sampleEml: "trezorsample.eml", eventId: "0x25e481b5d48c4024c6814361288b343c34b4fa95d5ee47f4574d7dbaeba3efe7" },
    { label: '"Make Waves on XRPL" — XRPL Commons', sampleEml: "xrpl.eml", eventId: "0x20388171b5a94010753d2bb2e408e2394ec79ac095730bd52c041d15b3b7751e" },
  ],
};

// Cross-type: "a unique human who attended {events}". World ID personhood + email event proofs,
// bound to the caller. statementId must match what DeployHumanEventGate registered.
export const HUMAN_EVENT = {
  statementId: keccak256(toUtf8Bytes("HUMAN_AND_LUMA")),
  contextId: 1n,
  label: "A verified human who attended Safe AI Lausanne",
  // Lighter demo: World ID + ONE event. To require more, deploy HumanEventGate with more EVENT_IDS
  // and list them here (must match the on-chain statement).
  events: [COMPOSE.events[0]],
};

// BN254 scalar field modulus.
export const P = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

// Minimal ABIs (only what the demo calls).
export const ABI = {
  verifiedHumansTree: [
    "function insertCredential(bytes32 commitment)",
    "function getRoot() view returns (bytes32)",
    "function getProof(bytes32 key) view returns (tuple(bytes32 root, bytes32[] siblings, bool existence, bytes32 key, bytes32 value, bool auxExistence, bytes32 auxKey, bytes32 auxValue))",
  ],
  claimsSmt: [
    "function getRoot() view returns (bytes32)",
    "function getProof(bytes32 key) view returns (tuple(bytes32 root, bytes32[] siblings, bool existence, bytes32 key, bytes32 value, bool auxExistence, bytes32 auxKey, bytes32 auxValue))",
    "function isRootValid(bytes32 root) view returns (bool)",
  ],
  redeemIssuer: [
    "function redeem(bytes32 providerId, uint64 expiresAt, bytes proof, bytes32[] pub)",
  ],
  emailEvidenceVerifier: [
    "function submitEvidence(bytes32 sourceId, bytes proof, bytes32[] pub)",
    "function consumedEmailNullifier(uint256) view returns (bool)",
  ],
  oneShotEmailGate: [
    "function present(bytes32 statementId, uint256 contextId, bytes proof, bytes32[] pub)",
    "function isPresented(uint256 nullifier) view returns (bool)",
    "function appScope(address caller, bytes32 statementId) view returns (uint256)",
  ],
  oneShotEmailVerifier: ["function verify(bytes proof, bytes32[] publicInputs) view returns (bool)"],
  multiEventEmailGate: [
    "function present(bytes32 statementId, uint256 contextId, bytes[] proofs, bytes32[][] pubs)",
    "function isPresented(uint256 nullifier) view returns (bool)",
  ],
  humanEventGate: [
    "function present(bytes32 statementId, uint256 contextId, (uint256 root, uint256 nullifierHash, uint256[8] proof) wid, bytes[] emailProofs, bytes32[][] emailPubs)",
    "function consumedHuman(bytes32,uint256,uint256) view returns (bool)",
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
  attestorIssuer: [
    "function attest(bytes32 subject, bytes32 claimType)",
    "function isSigner(address) view returns (bool)",
  ],
  claimsRegistry: [
    "function hasValidClaim(bytes32 subject, bytes32 claimType) view returns (bool)",
    "function getClaim(bytes32 subject, bytes32 claimType) view returns (tuple(address issuer, uint64 issuedAt, uint64 expiresAt))",
  ],
};

// Canonical claim type: keccak256("UNIQUE_HUMAN") mod p, as a field element (bigint).
// (Value hex: 0x28c2eef236608509ec93078138b2b9ae971aeecd1e018b1880231789d5402b55)
export const CLAIM_UNIQUE_HUMAN_NAME = "UNIQUE_HUMAN";

// Phase-1 claim types are plain keccak256(name) bytes32 (per DeployWorldIDStack.s.sol).
// The Vouch spike issues EVENT_TICKET_LUMA — register it on-chain with the SAME value
// (see VOUCH_SPIKE.md for the owner txs).
export const CLAIM_EVENT_TICKET_LUMA_NAME = "EVENT_TICKET_LUMA";
export const CLAIM_EVENT_TICKET_LUMA = keccak256(toUtf8Bytes(CLAIM_EVENT_TICKET_LUMA_NAME));
