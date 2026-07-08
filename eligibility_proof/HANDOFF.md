# eligibility_proof — Circuit A (generalized membership)

Phase-3 eligibility circuit (see `contracts/PHASE3_UNLINKABLE_DESIGN.md` §3). Generalizes the
archived `membership_proof` to a conjunction of claim inclusions + an app-scoped nullifier.

## Run (WSL, same toolchain as membership_proof)

```bash
cd eligibility_proof
nargo test --show-output          # logic validation (5 tests)
# later, once a fixture exists:
nargo execute                     # witness -> proof inputs (needs Prover.toml)
```

`nargo test` needs no `Prover.toml` — the tests derive public inputs from the witness with the
circuit's own helpers (true end-to-end happy paths + should_fail cases).

## What the 5 tests cover

- `test_eligibility_single_claim` — one active claim included + valid nullifier (happy path).
- `test_never_expires` — `expires_at == 0` accepted arbitrarily far in the future.
- `test_expired_rejected` — `expires_at <= now_ts` rejects.
- `test_bad_root_rejected` — wrong root rejects.
- `test_wrong_nullifier_rejected` — nullifier must bind `secret + app_id + context_id`.

These use single-leaf trees (all-zero siblings ⇒ root = leaf hash), which exercises every new code
path: identity commitment, `Poseidon2(idc, claimType)` keying, expiry, the app-scoped nullifier,
and sentinel-slot skipping (`claim_type == 0`).

## Public-input order (contract with the Solidity gate)

`[root, nullifier, app_id, context_id, now_ts, claim_types[MAX_CLAIMS], signal]`

The gate: checks `root` is a recent claims root, `now_ts ≈ block.timestamp`, `claim_types` equal the
registered statement's required set, then consumes `nullifier` for `[statementId][app][context_id]`.

## Real multi-leaf fixture (done — validated in Solidity)

A genuine conjunction fixture (one identity, 3 claim leaves + decoys, all under one root) is
generated and installed:

```bash
cd contracts
forge script script/GenerateEligibilityFixture.s.sol -vvv      # writes eligibility_prover.toml
cp eligibility_prover.toml ../eligibility_proof/Prover.toml
cd ../eligibility_proof && nargo execute                        # <- the remaining WSL confirmation
```

`Prover.toml` in this dir is already the generated fixture. `contracts/test/EligibilityFixture.t.sol`
ports the circuit's `compute_root` to Solidity and asserts it reproduces the real dl-solarity root
for every claim leaf — the multi-leaf "Check 2", **green**. So `nargo execute` should succeed; it's
the last Noir-side confirmation (the sandbox has no `nargo`).

## Deferred (next steps, in order)

1. **Poseidon compatibility recheck.** Same caveat as the archived circuit: confirm Noir's
   `bn254::hash_2/3` matches the iden3/circomlib Poseidon the on-chain dl-solarity SMT uses
   (`nargo test --show-output` prints; compare to circomlibjs). Must match before real proofs.
3. **UltraHonk Solidity verifier** export (`bb write_vk` / `bb contract`) + the app gate that wraps
   it (root freshness + nullifier consumption), mirroring how `WorldIDGate` wraps its verifier.
4. **anyOf** — add the `anyOfTypes[M] + selected` branch (spec §3 step 3) once allOf is fixture-green.

## Note

`MAX_CLAIMS = 4`, `TREE_DEPTH = 20` (globals in `src/main.nr`). Unused claim slots use `claim_type = 0`
and must carry zeroed `issuer_id/expires_at/siblings`. The archived `membership_proof/` is untouched.
