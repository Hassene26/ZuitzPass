# World ID — live end-to-end on the deployed World Chain Sepolia stack

This is the follow-on to [`WORLDID_PATH.md`](WORLDID_PATH.md). Here we make a real proof
**issue a claim on-chain** against the live Phase-1 deployment, then watch a statement become
satisfiable.

> **✅ Executed 2026-07-05.** A real IDKit-v4 simulator proof (no orb/passport) verified against
> the live router through the gate and issued `UNIQUE_HUMAN_WORLDID` on-chain — tx
> `0x5fc84d0046ad4f622c8bbc9d1f97750b3153c35fc3062856c08c0ffe4af91525`, subject
> `0x09893cd1…5f84`, `hasValidClaim`=true. After attesting `ZUITZ_MAY25_ATTENDEE` to the same
> subject, `check(subject, ZUITZ_LAUNCH_WORLDID)` = **true**. The steps below are the reproducible
> runbook.

## Deployed addresses (World Chain Sepolia, 4801)

| Contract | Address |
|---|---|
| **WorldIDGate (live, real appId)** | `0x67188d45F49854e0112dfC7c4c002527fdFF99BC` |
| ~~WorldIDGate (placeholder appId — revoked)~~ | ~~`0x7b6E5f3bA066d0c45f5C31e64256E4d85B55E105`~~ |
| ClaimsRegistry | `0x5d74F3a39C465f48d545757e65AcCbe55197765B` |
| StatementRegistry | `0x9518201b65b3b9a26a80cf7605952620c9498001` |
| AttestorIssuer | `0x03d8feaf664074a88c0f28596ae4fa79c24fef7f` |
| ZuitzerlandGovernance | `0x2706b28096157F884182a6ec37073b361ebc86AB` |

`UNIQUE_HUMAN_WORLDID` claim type = `0x4f84a3f267f236ed8728a6a419d4b3000de55d15acbcc6e3e4503d4d9bb3a3f8`
Launch statement id = `0x0767b4d8791ef6b37103f77cd4cf05a9932c60a392f5728ac59ad3fadb898191`

## 0. Prereqs

- A **World ID 4.0** app in the [Developer Portal](https://developer.world.org): keep `app_id`,
  `rp_id`, and the secret `signing_key`; add an **Incognito Action** `zuitzpass-access`. (World ID
  moved to v4 — staging is an `environment` setting, not an `app_staging_` prefix.)
- Testnet ETH on World Chain Sepolia for the deploying/submitting EOA.
- `export PK=<your key>` (or `--account <name>`) and
  `export RPC=https://worldchain-sepolia.g.alchemy.com/public`.

## 1. Capture a simulator proof

Use the IDKit-v4 capture app: **`contracts/frontend-idkit/`** (see its README). It runs the RP
backend + `IDKitRequestWidget` with `environment:"staging"` + the `orbLegacy` preset, and prints
the fixture JSON. Copy it into `test/fixtures/worldid_proof.json`. Set the `signal` to the address
you'll submit `verify()` from — the gate recomputes `keccak256(abi.encodePacked(signal))>>8`, which
IDKit's `orbLegacy` matches exactly.

## 2. Validate the proof for FREE (no gas) before deploying

```bash
cd contracts
PROOF_FIXTURE=test/fixtures/worldid_proof.json FORK=true \
  forge test --match-test test_RealProof_Replay -vvv
```

Green = the proof verifies against the real router. Only proceed once this passes.

## 3. Redeploy the gate with your real appId + re-wire issuance

```bash
CLAIMS_REGISTRY=0x5d74F3a39C465f48d545757e65AcCbe55197765B \
APP_ID=app_staging_<yours> ACTION=zuitzpass-access \
OLD_GATE=0x7b6E5f3bA066d0c45f5C31e64256E4d85B55E105 \
  forge script script/RedeployWorldIDGate.s.sol --rpc-url $RPC --private-key $PK --broadcast
# note the printed "new WorldIDGate" address -> export NEWGATE=0x...
```

This deploys a proof-capable gate, calls `setClaimsRegistry`, permissions it as the
`UNIQUE_HUMAN_WORLDID` issuer, and revokes the old placeholder gate. (Must be run by the
ClaimsRegistry owner EOA.)

## 4. Submit the proof to the LIVE gate → issues the claim on-chain

```bash
# values from your fixture:
SIGNAL=0x...            # same address you signed with
ROOT=0x...              # merkle_root
NULLIFIER=0x...         # nullifier_hash
# proof as a bracketed 8-uint array, e.g. "[0x..,0x..,...]"
cast send $NEWGATE "verify(address,uint256,uint256,uint256[8])" \
  $SIGNAL $ROOT $NULLIFIER "[$P0,$P1,$P2,$P3,$P4,$P5,$P6,$P7]" \
  --rpc-url $RPC --private-key $PK
```

On success: `AccessGranted` emitted, nullifier consumed, and the §2.3 hook issues
`UNIQUE_HUMAN_WORLDID` to the World-ID subject.

## 5. Verify the claim landed + drive the statement

```bash
CLAIMS=0x5d74F3a39C465f48d545757e65AcCbe55197765B
UHW=0x4f84a3f267f236ed8728a6a419d4b3000de55d15acbcc6e3e4503d4d9bb3a3f8
# subject = keccak256(abi.encode("worldid", nullifierHash))
SUBJECT=$(cast keccak $(cast abi-encode "f(string,uint256)" "worldid" $NULLIFIER))
cast call $CLAIMS "hasValidClaim(bytes32,bytes32)(bool)" $SUBJECT $UHW --rpc-url $RPC   # -> true

# The launch statement also needs ZUITZ_MAY25_ATTENDEE. Attest it to the SAME subject
# (organizer signer = ClaimsRegistry owner by default):
ATTESTOR=0x03d8feaf664074a88c0f28596ae4fa79c24fef7f
ATT=$(cast keccak "ZUITZ_MAY25_ATTENDEE")
cast send $ATTESTOR "attest(bytes32,bytes32)" $SUBJECT $ATT --rpc-url $RPC --private-key $PK

STMT=0x9518201b65b3b9a26a80cf7605952620c9498001
SID=0x0767b4d8791ef6b37103f77cd4cf05a9932c60a392f5728ac59ad3fadb898191
cast call $STMT "check(bytes32,bytes32)(bool)" $SUBJECT $SID --rpc-url $RPC   # -> true
```

`check → true` on the live deployment, driven by a real World ID proof, is the end-to-end
milestone. A `SubsidyPool` (`DeploySubsidyPool.s.sol`, `STATEMENT_ID=$SID`) then lets that subject
`consume` for a payout.

## Gotchas

- **appId/action must match** what the proof was generated with, on both the gate and IDKit — a
  mismatch reverts inside the router.
- **signal must match** the value passed to IDKit, or `verifyProof` reverts.
- One nullifier per `(appId, action)`; re-submitting the same proof reverts `DuplicateNullifier`.
