# Zuitzerland / ZuitzPass — Project Status

_Last updated: 2026-07-03 (architecture review + verdicts)_

## Verdicts (2026-07-03 review)

1. **ERC-7812 / Path B is CUT from the product.** The Ethereum singleton
   (`0x781246…7812`) is deployed but empty — zero users, no registrar, and Rarimo's native
   state transfer to L1 is "under construction". A gate against it authenticates nobody.
   The circuit work is **archived, not deleted**: `membership_proof/` + `ZuitzerlandVerifier`
   + the SMT fixture tooling are correct (Checks 1 & 2 passed against the real dl-solarity
   SMT) and become relevant **only if** the singleton ever gets a live registrar. Until
   then: no further work, no maintenance, excluded from deploys and docs describing the
   product. Kept in-tree as reference.

2. **Rarimo / Path A is THE architecture.** `ZuitzPassExecutor is AQueryProofExecutor`
   on **Rarimo L2** (chainId 7368, RPC `https://l2.rarimo.com`), pointed directly at the
   live `RegistrationSMT` `0x479F84502Db545FA8d2275372E0582425204A879` (re-verified live
   2026-07-03: non-zero root, `ROOT_VALIDITY` 3600s). No replicator needed on L2.

3. **§9 extensibility vision (evidence ladder + attestation indirection): kept as a
   design note, not built.** It's sound as a v2 direction; v1 ships one provider.

## Path A — what is now CONFIRMED

- ✅ **Verifier VK == production circuit (closed 2026-07-03).** The vendored
  `TD3QueryProofVerifier` constants (alpha/beta/gamma/delta + all 24 IC points, 23 public
  signals) are **identical** to `rarimo/verificator-svc` `proof_keys/passport.json` — the
  Groth16 key Rarimo's production off-chain service verifies live RariMe proofs with.
  Deploying our own verifier instance is also the pattern Rarimo's on-chain guide prescribes,
  so "no canonical deployment" is expected, not a gap.
- ✅ **Selector bits cross-validated** against the circuits README **and** verificator-svc's
  query-proof parameter table. This caught a real bug (fixed 2026-07-03):
  **uniqueness is selector 2560 = bits 9 + 11** (timestamp-upperbound OR identity-counter
  ≤ bound), not bits 10 + 11. `ZuitzPassExecutor` now sets `withTimestampLowerboundAndUpperbound(0,
  timestampUpperbound)` + `withIdentityCounterLowerbound(0, bound)` with a `timestampUpperbound`
  policy field (0 at init = deploy time). An SDK-generated proof would have reverted before.
- ✅ Unit tests (mocks) + fork tests against the live L2 tree (`FORK=true forge test
  --match-path test/ZuitzPassExecutor.fork.t.sol -vvv`).
- ✅ `DeployRarimo.s.sol` wires verifier + executor + governance (defaults target L2).

## Path A — the ONE remaining blocker

**Capture one genuine RariMe Query proof and replay it** (`test_RealProof_Replay`,
runbook in `docs/RARIMO_PATH.md §6`). This is the only end-to-end confirmation left —
selector/criteria/signal agreement with the live prover. Since testnet is down, do it on
production: register a real passport in RariMe (free), request a proof via
`@rarimo/zk-passport` / `verificator-svc` with the contract's exact policy (read
`exec.selector()` / `getPublicSignals`), record the **exact** `timestamp_upperbound` used,
fill `test/fixtures/rarimo_proof.json`, replay promptly (root < 1h) or pin the fork block.
If it reverts `InvalidCircomProof`, diff the SDK's 23 signals against
`exec.getPublicSignals(...)` — any residual mismatch is a one-line fix.

Then: **deploy on Rarimo L2** and wire the frontend (`@rarimo/zk-passport`).

## Path A′ — World ID (testable alternative, added 2026-07-04)

Rarimo's blocker is that producing a proof requires a **passport upload** the user can't do.
**World ID** is a second provider behind the *same* gate/governance/nullifier shape — and its
**simulator** issues valid proofs with **no orb/passport/personal data**, so the full ZK path
is end-to-end testable (the thing the Rarimo path can't reach).

- `src/WorldIDGate.sol` (calls the real World ID Router `verifyProof`) + `IWorldID` +
  `ByteHasher`; reuses `ZuitzerlandGovernance` via `INullifierBanControl`.
- Routers **verified live** (codesize) on World Chain Sepolia (4801,
  `0x57f928158C3EE7CDad1e4D8642503c4D0201f611`), Optimism Sepolia, Base Sepolia.
- Unit tests (mock) + fork test vs the real router + fixture-driven simulator-proof replay
  (`test/WorldIDGate.fork.t.sol`). Deploy: `script/DeployWorldID.s.sol`. Runbook +
  how-to-get-a-simulator-proof: `docs/WORLDID_PATH.md`.
- This is the pluggable-provider design (ARCHITECTURE.md §9) paying off: Rarimo and World ID
  are two adapters behind one gate.

## Phase 1 — statements layer (built 2026-07-04, `ARCHITECTURE_UPDATED.md` §2/§8)

The provider gates are now **issuers** behind a two-layer statements system (evidence→claims,
claims→statements). New, all unit-tested:

- `src/ClaimsRegistry.sol` — typed claims per subject (`keccak256(providerId, nullifier)`),
  owner-registered claim types, per-type issuer allowlist, issue/revoke, `hasValidClaim`
  (exists && !expired && !banned). Layer-wide subject bans via `INullifierBanControl`, so the
  existing `ZuitzerlandGovernance` drives it unchanged — one ban kills all of a subject's claims.
- `src/StatementRegistry.sol` — `Statement{allOf, anyOf, consumable, metadataURI}`; `check`
  (view) and `consume` keyed `[statementId][app][contextId][subject]` (per-app, per-context;
  anyOf short-circuits, empty anyOf skipped).
- `src/issuers/AttestorIssuer.sol` — owner-managed signer allowlist → `claims.issue` (zero-ZK).
- `src/issuers/OnchainReadIssuer.sol` — zero-ZK issuer for public on-chain state (§2.4): owner sets
  a per-claim-type `Condition{token, minBalance, validity}`, `issueClaim` reads `balanceOf` and
  mints the claim to the **wallet-linked** subject `keccak256("onchain", account)`. Short validity
  windows since balances change. Completes the Phase-1 issuer set.
- **Issuer hooks (additive, opt-in):** both gates gained an owner-set `claimsRegistry`
  (zero = off, Phase-0 behavior unchanged) + `claimValidity` (default 180d). On success
  `ZuitzPassExecutor` issues `UNIQUE_HUMAN_RARIMO` (always) + `OVER_18` (iff age gate on);
  `WorldIDGate` issues `UNIQUE_HUMAN_WORLDID`. Each gate keeps its own `usedNullifiers`
  proof-replay guard. **None of the validated ZK plumbing (VK, selector bits, root freshness,
  router call) was touched.**
- `script/DeployStatements.s.sol` — deploys registries + attestor, wires governance + issuers,
  registers the four demo claim types + the §8 `ALPS_RESIDENCY_2026` statement (env-configurable).
- `src/demo/SubsidyPool.sol` (+ `script/DeploySubsidyPool.s.sol`) — the §8 **consumer**: a
  funds-holding pool that pays a subsidy gated purely on `check`/`consume`, once per epoch
  (`contextId = block.timestamp / epochLength`). `consume` commits before payout → reentrancy-safe.
  This is the Phase-1 exit-criterion piece: a real app gating a real thing. **Trust boundary:**
  it trusts the caller controls `subject` (Phase-1 pseudonymous); trustless binding is Phase 3.
- Tests: `test/ClaimsRegistry.t.sol`, `test/StatementRegistry.t.sol`, `test/AttestorIssuer.t.sol`,
  `test/Issuance.t.sol` (both hooks, registry mocked), `test/StatementsIntegration.t.sol`
  (the full Alice §8 flow: gate verify → claim issued → statement check → consume → re-consume
  reverts + layer-wide ban), `test/SubsidyPool.t.sol` (consumer payout, per-epoch, reentrancy),
  `test/OnchainReadIssuer.t.sol` (balance threshold, expiry, permissioning).
  **89 unit tests green** (`forge test`, non-fork).
- **Browser demo** (`contracts/frontend/` + `script/DeployDemo.s.sol` + `src/demo/DemoToken.sol`):
  a local-anvil, no-ZK walkthrough of evidence→claims→statement→consume. Verified end to end
  (mint → issue → attest → eligible → claim pays 0.1 ETH → re-claim reverts). See
  `contracts/frontend/README.md`.

**Repo cleanup:** the archived Path-B stack (`ZuitzerlandVerifier`, provider adapters,
`NoirVerifierWrapper` + their tests/mocks/deploy script) moved to `contracts/src/archive/`,
`contracts/test/archive/`, `contracts/script/archive/` (see the archive READMEs). `membership_proof/`
untouched (dormant until Phase 3).

## To do (ordered)

0. [ ] Run the Phase-1 unit tests (`forge test` — see the commands block below).
1. [ ] Run `forge build && forge test` in WSL (OZ-upgradeable dep per
       `contracts/src/rarimo/VENDORED.md`) — includes Rarimo + World ID unit tests.
2. [ ] `FORK=true` fork tests (Rarimo live L2 + World ID World Chain Sepolia router).
3. [x] **World ID end-to-end DONE (2026-07-05): live on-chain proof.** A real IDKit-v4 simulator
       proof (no orb/passport, `orbLegacy` preset) verified against the live World Chain Sepolia
       router through the gate AND issued `UNIQUE_HUMAN_WORLDID` on-chain (tx `0x5fc84d00…91525`,
       `hasValidClaim`=true, 180d expiry). Fork test `test_RealProof_Replay` green. Live gate
       (real appId): `0x67188d45F49854e0112dfC7c4c002527fdFF99BC`. Capture tooling:
       `contracts/frontend-idkit/` (IDKit v4 + RP backend); runbook `docs/WORLDID_LIVE_REPLAY.md`.
       (Rarimo real-proof replay stays pending a passport.)
4. [ ] Deploy on Rarimo L2; smoke-test `execute()` with a fresh proof.
5. [ ] Frontend: request proofs with policy read from the contract getters.
6. [ ] Commit this review (selector fix + docs) — Path B code stays as archive.

## Deferred (V2)

- Per-action nullifiers (`eventData`/`actionId` scoping) for repeated actions.
- Vote-based governance bans (quorum of members via ZK proof).
- Second provider (zkPassport — different model, unconfirmed fit) / evidence-source
  ladder + attestation indirection (`contracts/ARCHITECTURE.md §9`).
- zkTLS provider (`docs/ZKTLS_PROVIDER_NOTE.md`).

## Map of the repo (post-review)

| Area | Status |
|---|---|
| `contracts/src/ZuitzPassExecutor.sol` + rarimo vendored SDK | **Product (Path A)** — also issuer #1 |
| `contracts/src/WorldIDGate.sol` | **Product (Path A′)** — issuer #2 |
| `contracts/src/ClaimsRegistry.sol`, `StatementRegistry.sol`, `issuers/AttestorIssuer.sol` | **Product (Phase 1)** — statements layer |
| `contracts/src/demo/SubsidyPool.sol` | **Demo consumer (Phase 1)** — example app gating a payout on `check`/`consume` |
| `contracts/src/ZuitzerlandGovernance.sol` (`INullifierBanControl`) | **Product** — drives both gates **and** the ClaimsRegistry |
| `contracts/script/DeployRarimo.s.sol`, `DeployWorldID.s.sol`, `DeployStatements.s.sol`, `test/*` | **Product** |
| ~~Path B (`ZuitzerlandVerifier`, adapters, `NoirVerifierWrapper`) + `membership_proof/`~~ | **Removed** in the cleanup — Path B superseded, and the membership circuit generalized into `eligibility_proof/` + `issuance_proof/` |
| SMT fixture tooling (`test/fixtures/`, `Generate*Fixture`) | **Product (Phase 3)** — real dl-solarity fixtures for the circuits |
| `docs/E2E_FLOW_RARIMO.md`, `docs/RARIMO_PATH.md`, `docs/RARIMO_INTEGRATION_MAPPING.md` | Current |
| `contracts/ARCHITECTURE.md` §1–8 | Describes the **archived** Path B — read §9 + Rarimo docs for the product |
