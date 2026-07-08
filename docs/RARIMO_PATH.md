# ZuitzPass — Rarimo Path: Wiring & Client Usage

_How to deploy, configure, and call `ZuitzPassExecutor` (the Rarimo-path gate). Companion to
[`E2E_FLOW_RARIMO.md`](E2E_FLOW_RARIMO.md) (the flow) and
[`RARIMO_INTEGRATION_MAPPING.md`](RARIMO_INTEGRATION_MAPPING.md) (the design)._

---

## 1. Contracts

| Contract | Role |
|---|---|
| `src/ZuitzPassExecutor.sol` | The gate. Inherits Rarimo's `AQueryProofExecutor`. Verifies a passport Query proof + enforces ZuitzPass policy (nullifier, uniqueness, optional age / not-expired). |
| `src/ZuitzerlandGovernance.sol` | Owner-driven ban/unban of nullifiers (via `INullifierBanControl`). |
| `src/rarimo/**` | Vendored Rarimo SDK (`AQueryProofExecutor`, `PublicSignalsBuilder`, `IPoseidonSMT`, …). Do not edit — see `src/rarimo/VENDORED.md`. |
| **External (deployed by Rarimo)** | `TD3QueryProofVerifier` (Groth16) and `RegistrationSMTReplicator` / registration SMT (`IPoseidonSMT`). We only *call* these. |

```
client ──execute()──▶ ZuitzPassExecutor ──verifyProof()──▶ TD3QueryProofVerifier (Groth16)
                            │  └─isRootValid()──▶ RegistrationSMTReplicator (1h freshness)
   ZuitzerlandGovernance ──setNullifierBanned()──┘
```

---

## 2. Deploy

```bash
# in contracts/ (WSL)
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0 --no-commit  # once
forge build

REGISTRATION_SMT=0x...   # RegistrationSMTReplicator (or SMT) on your target chain
QUERY_VERIFIER=0x...     # Rarimo TD3QueryProofVerifier (Groth16)
EVENT_ID=0x5a55495450415353   # fixed ZuitzPass scope (any 31-byte-safe uint256)
forge script script/DeployRarimo.s.sol --rpc-url $RPC --broadcast
```

Optional policy env (defaults in parentheses): `OWNER` (broadcaster), `ID_COUNTER_MAX` (1),
`REQUIRE_UNIQUENESS` (true), `REQUIRE_NOT_EXPIRED` (true), `BIRTHDATE_UPPERBOUND` (0 = age off),
`CURRENT_DATE_TIME_BOUND` (86400).

The script deploys the executor, `initialize`s it, deploys governance, and calls
`exec.setGovernance(gov)`.

---

## 3. Policy — the contract is the source of truth

The gate's criteria are on-chain policy, set at `initialize` and adjustable by the owner via
`setPolicy(...)`:

| Field | Meaning |
|---|---|
| `eventId` | Fixed scope. Makes the nullifier untraceable across apps and stable per (person, ZuitzPass) → one human, one account. |
| `requireUniqueness` + `identityCounterUpperbound` + `timestampUpperbound` | Rarimo's uniqueness OR-check (verificator-svc selector 2560, bits 9+11): identity registered before `timestampUpperbound` (unix ts; 0 at init = deploy time) OR identity counter ≤ bound (e.g. 1). |
| `requireNotExpired` | Prove passport expiration > `currentDate`. |
| `birthDateUpperbound` (0 = off) | Prove birth date ≤ this `yyMMdd` (age gate). |
| `currentDateTimeBound` | How far `currentDate` may sit from `block.timestamp` (freshness). |

`selector()` returns the exact bitmask these produce. **The client MUST generate its Query
proof with parameters matching this policy**, or the public signals won't match and
`execute` reverts. Read the policy from the getters (or `getPublicSignals`) before proving.

---

## 4. Client call

The proof itself comes from **RariMe / `@rarimo/zk-passport`** (the user's device), for a Query
with ZuitzPass's `eventId` + criteria. That yields the Groth16 proof points and the public
signals (including the `nullifier`). Then:

```solidity
// 1) Application payload (ABI-encoded struct)
ZuitzPassExecutor.QueryPayload memory payload = ZuitzPassExecutor.QueryPayload({
    nullifier: PROOF_NULLIFIER,                 // public signal #0 from the proof
    eventData: uint256(uint160(userWallet))     // arbitrary binding (e.g. wallet)
});

// 2) Groth16 proof points from the SDK
AQueryProofExecutor.ProofPoints memory zk = AQueryProofExecutor.ProofPoints({a: a, b: b, c: c});

// 3) Call the gate
exec.execute(
    registrationRoot,   // bytes32 — the root the proof was generated against
    currentDate,        // uint256 — yyMMdd ASCII in the low 6 bytes (e.g. "260703")
    abi.encode(payload),
    zk
);
```

- **`currentDate` encoding:** 6 ASCII bytes `yyMMdd` packed big-endian into the low 6 bytes,
  e.g. 2026-07-03 → `0x323630373033`. Year is `yy + 2000`. Must be within
  `currentDateTimeBound` of `block.timestamp`.
- On success: the nullifier is marked used and `AccessGranted(caller, nullifier, eventData)`
  fires. A second call with the same nullifier reverts `NullifierAlreadyUsed`.

### Preview signals without verifying
`exec.getPublicSignals(registrationRoot, currentDate, abi.encode(payload))` returns the full
`bytes32[23]` the contract will check — handy for the client to confirm it built a matching proof.

---

## 5. Frontend surface

**Events:** `AccessGranted(address indexed caller, bytes32 indexed nullifier, uint256 eventData)`.
**Reverts to handle:** `NullifierBanned`, `NullifierAlreadyUsed`, `NotGovernance`,
`PublicSignalsBuilder.InvalidRegistrationRoot` (stale/unknown root),
`AQueryProofExecutor.InvalidCircomProof` (proof failed), `InvalidDate` (currentDate out of range).

**Public signal layout (index → meaning),** for reference:

| idx | signal | idx | signal |
|--|--|--|--|
| 0 | nullifier | 13 | currentDate |
| 9 | eventId | 14/15 | timestamp lower/upper |
| 10 | eventData | 16/17 | identity counter lower/upper |
| 11 | idStateRoot | 18/19 | birth date lower/upper |
| 12 | selector | 20/21 | expiration lower/upper |
|   |  | 22 | citizenship mask |

---

## 6. Capturing a real proof (to run the replay test)

The one thing mocks + a fork can't do is produce a genuine proof — that needs a real
registered identity. Once you have **one**, `test_RealProof_Replay` validates the whole ZK
path (and confirms our selector bits match the live circuit). Steps:

1. **Register** a passport in the **RariMe** app (one-time; reused across Rarimo apps).
2. **Generate a Query proof** with `@rarimo/zk-passport`, using **exactly** ZuitzPass's
   parameters so the public signals match what our contract builds:
   - `eventId` = your ZuitzPass scope (default `0x5a55495450415353`)
   - uniqueness on (identity-counter upper = 1 **and** record the exact
     `timestamp_upperbound` used — it must go into the fixture); age off; not-expired off
   - the `eventData` you'll pass on-chain (e.g. the user's wallet)
   Tip: `exec.getPublicSignals(root, currentDate, abi.encode(nullifier, eventData))` returns
   the exact 23 signals our contract expects — compare against the SDK's output.
3. **Capture** into `test/fixtures/rarimo_proof.json` (copy the `.example.json`): the
   `registrationRoot`, `currentDate` (yyMMdd ASCII), `nullifier`, `eventData`, and the Groth16
   `proofA` (2) / `proofB` (4, row-major `[b00,b01,b10,b11]`) / `proofC` (2). Keep the policy
   fields identical to step 2.
4. **Replay** promptly (the root must still be valid — latest, or < 1h old — or pin the fork to
   the capture block):
   ```bash
   PROOF_FIXTURE=test/fixtures/rarimo_proof.json FORK=true \
     forge test --match-test test_RealProof_Replay -vvv
   ```

If it passes: the real proof is accepted → **selector bits + verifier VK confirmed.** If it
reverts `InvalidCircomProof`, the signals our contract built don't match the proof — usually a
selector-bit or criteria mismatch (fix the `SEL_*` consts or align the policy), or a swapped
`proofB` coordinate order.

---

## 7. Before mainnet (open items)

0. ~~**Verifier VK**~~ — **CLOSED (2026-07-03).** The vendored `TD3QueryProofVerifier`'s
   verification key matches, constant-for-constant (alpha/beta/gamma/delta + all 24 IC
   points), the Groth16 key Rarimo's production `verificator-svc` uses to verify live RariMe
   proofs (`proof_keys/passport.json` @ main). Deploying our own instance is also the
   pattern Rarimo's own on-chain guide prescribes.
1. **Selector bits** (`SEL_*` in `ZuitzPassExecutor`) — cross-validated against the circuits
   README **and** verificator-svc's parameter table (uniqueness = 2560 = bits 9+11; the
   contract now mirrors that, including the `timestampUpperbound` cutoff). Final
   confirmation is the real-proof replay; a residual mismatch is a one-line const fix.
2. **Age date** — when enabling `birthDateUpperbound`, compute it as "today − 18y" (`yyMMdd`
   ASCII). Currently an owner-set static value; a keeper/helper should refresh it as the date
   advances.
3. **Real addresses + chain** — `TD3QueryProofVerifier` + `RegistrationSMTReplicator` per
   target chain, then a fork test against the real verifier.
