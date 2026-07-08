# ZuitzPass statements-layer demo (local)

A zero-dependency browser demo of the Phase-1 flow **evidence → claims → statement → consume**,
using the two zero-ZK issuers (`AttestorIssuer`, `OnchainReadIssuer`) so no proofs are needed in
the browser. The ZK gates (`ZuitzPassExecutor`, `WorldIDGate`) plug in as issuers the same way.

## Run it

```bash
# 1. Start a local chain
anvil

# 2. Deploy the demo stack (writes frontend/addresses.json)
cd contracts
forge script script/DeployDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 3. Serve the frontend
python3 -m http.server 5173 --directory frontend
# open http://127.0.0.1:5173
```

## What you'll see

1. **Mint membership NFT to Alice** (organizer) — gives Alice the on-chain state to read.
2. **Issue HOLDS_NFT claim** (anyone) — `OnchainReadIssuer` reads her balance → writes the claim.
3. **Organizer attests ATTENDEE** (signer) — `AttestorIssuer` writes the attendance claim.
   → the statement `attended AND holds NFT` now evaluates **eligible**.
4. **Claim subsidy** — the `SubsidyPool` calls `consume(subject, statementId, epoch)` and pays
   0.1 ETH. A second claim in the same epoch reverts `AlreadyConsumed`.

> **Dev only.** `app.js` signs with anvil's well-known default keys — never use them on a real
> network. The demo uses the wallet-linked subject so claims from different issuers compose.
