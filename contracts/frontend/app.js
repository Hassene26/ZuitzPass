/*
 * ZuitzPass statements-layer demo frontend.
 * Talks directly to a local anvil via ethers + dev private keys (NO wallet extension needed).
 * DEV ONLY — these keys are anvil's well-known defaults; never use them on a real network.
 */
const RPC_URL = "http://127.0.0.1:8545";

// anvil default accounts
const ORGANIZER_PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // acct0: owner/organizer/signer
const ALICE_PK = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // acct1: Alice

// Minimal ABIs (only what the demo calls).
const ABI = {
  token: ["function mint(address to, uint256 amount)", "function balanceOf(address) view returns (uint256)"],
  onchain: [
    "function issueClaim(bytes32 claimType, address account)",
    "function subjectOf(address account) view returns (bytes32)",
  ],
  attestor: ["function attest(bytes32 subject, bytes32 claimType)"],
  claims: ["function hasValidClaim(bytes32 subject, bytes32 claimType) view returns (bool)"],
  pool: [
    "function claim(bytes32 subject)",
    "function eligible(bytes32 subject) view returns (bool)",
    "function hasClaimedThisEpoch(bytes32 subject) view returns (bool)",
    "function payoutAmount() view returns (uint256)",
  ],
};

const $ = (id) => document.getElementById(id);
function log(msg, cls = "log-dim") {
  const el = $("log");
  const line = document.createElement("div");
  line.className = cls;
  line.textContent = `${new Date().toLocaleTimeString()}  ${msg}`;
  el.appendChild(line);
  el.scrollTop = el.scrollHeight;
}

let A = {}; // addresses.json
let provider, organizer, alice;
let c = {}; // contracts (read via provider)
let subject;

async function boot() {
  try {
    A = await (await fetch("./addresses.json")).json();
  } catch (e) {
    log("Could not load addresses.json — run DeployDemo.s.sol against anvil first.", "log-bad");
    return;
  }
  provider = new ethers.JsonRpcProvider(RPC_URL);
  organizer = new ethers.Wallet(ORGANIZER_PK, provider);
  alice = new ethers.Wallet(ALICE_PK, provider);

  c.token = new ethers.Contract(A.demoToken, ABI.token, provider);
  c.onchain = new ethers.Contract(A.onchainReadIssuer, ABI.onchain, provider);
  c.attestor = new ethers.Contract(A.attestorIssuer, ABI.attestor, provider);
  c.claims = new ethers.Contract(A.claimsRegistry, ABI.claims, provider);
  c.pool = new ethers.Contract(A.subsidyPool, ABI.pool, provider);

  subject = await c.onchain.subjectOf(alice.address);
  $("aliceAddr").textContent = short(alice.address);
  $("subject").textContent = short(subject);
  log("Connected to anvil. Loaded demo contracts.", "log-ok");
  await refresh();
}

function short(h) {
  return h.length > 14 ? `${h.slice(0, 10)}…${h.slice(-6)}` : h;
}

async function refresh() {
  const [attend, nft, eligible, claimed, aBal, pBal] = await Promise.all([
    c.claims.hasValidClaim(subject, A.attendeeClaimType),
    c.claims.hasValidClaim(subject, A.holdsNftClaimType),
    c.pool.eligible(subject),
    c.pool.hasClaimedThisEpoch(subject),
    provider.getBalance(alice.address),
    provider.getBalance(A.subsidyPool),
  ]);

  setClaim("cAttend", attend);
  setClaim("cNft", nft);

  const badge = $("eligible");
  badge.textContent = eligible ? "YES" : "NO";
  badge.className = `badge ${eligible ? "ok" : "bad"}`;

  $("claimed").textContent = claimed ? "yes" : "no";
  $("aliceBal").textContent = `${(+ethers.formatEther(aBal)).toFixed(4)} ETH`;
  $("poolBal").textContent = `${(+ethers.formatEther(pBal)).toFixed(2)} ETH`;
  $("btnClaim").disabled = !eligible || claimed;
}

function setClaim(id, present) {
  const el = $(id);
  el.textContent = present ? "present ✓" : "absent";
  el.className = `v ${present ? "yes" : "no"}`;
}

async function tx(label, promise) {
  try {
    log(`${label} …`);
    const t = await promise;
    await t.wait();
    log(`${label} ✓  (${short(t.hash)})`, "log-ok");
    await refresh();
  } catch (e) {
    const reason = e?.revert?.name || e?.shortMessage || e?.message || String(e);
    log(`${label} reverted: ${reason}`, "log-bad");
    await refresh();
  }
}

function wire() {
  $("btnMint").onclick = () =>
    tx("Mint membership NFT → Alice", c.token.connect(organizer).mint(alice.address, 1));
  $("btnOnchain").onclick = () =>
    tx("Issue HOLDS_NFT claim", c.onchain.connect(alice).issueClaim(A.holdsNftClaimType, alice.address));
  $("btnAttest").onclick = () =>
    tx("Attest ATTENDEE", c.attestor.connect(organizer).attest(subject, A.attendeeClaimType));
  $("btnClaim").onclick = () => tx("Alice claims subsidy", c.pool.connect(alice).claim(subject));
  $("btnRefresh").onclick = refresh;
}

wire();
boot();
