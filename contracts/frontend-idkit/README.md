# World ID proof capture (IDKit v4 + RP backend)

World ID migrated to **v4**, which (a) makes staging an explicit `environment` setting and
(b) requires every verification request to carry an **RP (relying-party) signature** produced
server-side from a secret signing key. This app does both: a Vite dev server that also hosts the
RP-signing endpoint, plus the `IDKitRequestWidget` using the **`orbLegacy`** preset so the proof
is the **classic on-chain format** your deployed `WorldIDGate` verifies.

> The **free fork test is the compatibility oracle**: once you have the fixture, running
> `test_RealProof_Replay` tells you definitively whether the `orbLegacy` proof verifies against
> your gate — no gas.

## 1. Portal setup (one-time)

At [developer.world.org](https://developer.world.org), open your app and click the
**"Enable World ID 4.0"** banner (or create a v4 app). Keep these three values:

- `app_id`  → `VITE_APP_ID`
- `rp_id`   → `VITE_RP_ID`
- `signing_key` (a **secret**) → `RP_SIGNING_KEY`

Add an **Incognito Action** `zuitzpass-access` on the app.

## 2. Configure

```bash
cd contracts/frontend-idkit
cp .env.example .env      # then fill in the four values above + VITE_SIGNAL (your wallet address)
npm install
npm run dev               # http://localhost:5174
```

Requires **Node 18+** (`node -v`; `nvm install 20` if missing).

## 3. Capture

1. Click **Prepare RP signature & open widget** → the backend signs the request, the widget opens.
2. Open https://simulator.worldcoin.org, connect/scan the QR, approve (it plays a staging
   Orb identity).
3. The **Fixture JSON** box fills in. Copy it into `../test/fixtures/worldid_proof.json`.
   (A raw-result box also appears — if the fixture looks wrong, share that so field names can be
   adjusted.)

## 4. Validate for free, then go on-chain

```bash
cd ..     # contracts/
PROOF_FIXTURE=test/fixtures/worldid_proof.json FORK=true \
  forge test --match-test test_RealProof_Replay -vvv
```

- **Green** → the proof is gate-compatible. Redeploy the gate with this `app_id`/`action`
  (`RedeployWorldIDGate.s.sol`) and submit on-chain — see `docs/WORLDID_LIVE_REPLAY.md`.
- **Reverts** → most likely the `orbLegacy` proof isn't wire-compatible with the classic
  `verifyProof`, or a signal/externalNullifier mismatch. Send me the raw result + revert and
  we'll adjust.

## Notes

- `RP_SIGNING_KEY` is secret — kept server-side (no `VITE_` prefix), never sent to the browser.
  `.env` is gitignored.
- `app_id`, `action`, and `signal` must be **identical** here, in the fixture, and in the eventual
  `gate.verify()` / `RedeployWorldIDGate` `APP_ID`.
