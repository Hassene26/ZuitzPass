# ZuitzPass — World ID Path (alternative provider, testable without a passport)

_Added because the Rarimo path is blocked on producing a passport proof. World ID gives the
same gate shape (proof-of-personhood + per-action nullifier) and — crucially — a **simulator**
that issues valid proofs with **no orb, no passport, no personal data.** This is the concrete
payoff of the pluggable-provider design in [`../contracts/ARCHITECTURE.md`](../contracts/ARCHITECTURE.md) §9._

---

## 1. Contracts

| Contract | Role |
|---|---|
| `src/WorldIDGate.sol` | The gate. Calls the World ID Router's `verifyProof`, tracks nullifiers, grants access. |
| `src/interfaces/IWorldID.sol` | Router interface (`verifyProof` is `view` and **reverts** on a bad proof). |
| `src/lib/ByteHasher.sol` | `hashToField` (keccak256 >> 8) for signal + external-nullifier. |
| `src/ZuitzerlandGovernance.sol` | Reused unchanged — bans/unbans nullifiers via `INullifierBanControl`. |
| **External (World ID)** | The **Router** (deployed by World; we only call it). |

```
client ──verify(signal, root, nullifierHash, proof)──▶ WorldIDGate ──verifyProof()──▶ World ID Router
   ZuitzerlandGovernance ──setNullifierBanned()──┘
```

## 2. Router addresses (verified live)

| Chain | chainId | Router |
|---|---|---|
| **World Chain Sepolia** (default) | 4801 | `0x57f928158C3EE7CDad1e4D8642503c4D0201f611` |
| Optimism Sepolia | 11155420 | `0x11cA3127182f7583EfC416a8771BD4d11Fae4334` |
| Base Sepolia | 84532 | `0x42FF98C4E85212a5D31358ACbFe76a621b50fC02` |
| World Chain (mainnet) | 480 | `0x17B354dD2595411ff79041f930e491A4Df39A278` |

Testnet routers verify **staging/simulator** identities — so we can go fully end-to-end without
any real biometric.

## 3. Deploy (World Chain Sepolia)

```bash
cd contracts
APP_ID=app_staging_xxxxxxxxxxxxxxxxxxxxxxxxxxxx ACTION=zuitzpass-access \
  forge script script/DeployWorldID.s.sol \
  --rpc-url https://worldchain-sepolia.g.alchemy.com/public --private-key $PK --broadcast
```

Deploys the gate + governance, wired. `WORLD_ID_ROUTER` overrides the chain default.

## 4. Get a real proof from the simulator (NO orb/passport)

1. Create an app in the **World Developer Portal** → get an `app_id` (use a **staging** app) and
   define an **action** (e.g. `zuitzpass-access`). Use these same values when deploying (§3).
2. Drive IDKit with `environment: "staging"` and the **simulator**
   (https://simulator.worldcoin.org): scan the QR with the simulator (it plays a verified
   identity), approve.
3. IDKit returns `{ merkle_root, nullifier_hash, proof }`. The `proof` is an ABI-encoded
   `uint256[8]` — decode it to 8 uints.
4. The **signal** must match on both sides: pass the same value (e.g. a wallet address) to IDKit
   and to `gate.verify(signal, …)`.

## 5. Replay it against the real router

Copy `test/fixtures/worldid_proof.example.json` → `worldid_proof.json`, fill `appId`, `action`,
`signal`, `root` (= merkle_root), `nullifierHash`, and the 8-element `proof`, then:

```bash
PROOF_FIXTURE=test/fixtures/worldid_proof.json FORK=true \
  forge test --match-test test_RealProof_Replay -vvv
```

Green = the full ZK path works against real World ID infrastructure. This is the milestone the
Rarimo path can't reach without a passport.

## 6. Client call (production shape)

```solidity
gate.verify(
    signal,        // address bound into the proof (e.g. user wallet)
    root,          // uint256 merkle_root from IDKit
    nullifierHash, // uint256 nullifier_hash from IDKit
    proof          // uint256[8] decoded from IDKit's proof
);
// success -> nullifier consumed, AccessGranted emitted; reuse reverts DuplicateNullifier
```

## 7. Notes / caveats

- **groupId = 1** (Orb credential) is hardcoded. Simulator identities are Orb-tier in staging.
- **Signal encoding must match** what IDKit signed, or `verifyProof` reverts — same class of
  gotcha as the Rarimo path.
- Uniqueness is per `(appId, action)`: one human → one nullifier for this action. For multiple
  one-time actions, use distinct actions (distinct `externalNullifier`).
- Staging/simulator ≠ real Sybil resistance; it proves the *integration*. Production uses a
  live app + real World ID users.
- World ID and Rarimo are two adapters behind the same governance/nullifier gate — exactly the
  ARCHITECTURE.md §9 model. A future `IIdentityAdapter` could normalize both.
