# issuance_proof — Circuit B (private issuance binding)

Phase-3 strong private binding (`contracts/PHASE3_UNLINKABLE_DESIGN.md` §4/§4.1). Privately redeems
a per-provider verified-humans credential into a claim leaf on the master identity — revealing
neither the credential `C`, the provider nullifier, nor `idc`. Reuses Circuit A's `compute_root`.

## Run (WSL)

```bash
cd issuance_proof
nargo test --show-output          # 4 tests (happy path + 3 should_fail)
```

## What the tests cover

- `test_redeem_happy_path` — membership + correct `leaf_key` + `redeem_nullifier` derivation.
- `test_bad_cred_root_rejected` — non-member rejects.
- `test_wrong_leaf_key_rejected` — `leaf_key` must equal `Poseidon2(idc, claim_type)` (can't write
  to another identity).
- `test_wrong_redeem_nullifier_rejected` — `redeem_nullifier` must equal `Poseidon2(r, claim_type)`.

Single-leaf credential trees (all-zero siblings ⇒ `cred_root` = leaf hash) exercise every path.

## Public-input order (contract with the redeem entrypoint)

`[cred_root, claim_type, leaf_key, redeem_nullifier]`

Redeem entrypoint (the `ClaimsSMTRegistry.redeemer`): verify → `cred_root` fresh → `(provider,
claim_type)` permissioned → `redeem_nullifier` unused (consume) → `expiresAt <= now + maxValidity`
→ `claimsSmt.addClaimLeaf(leaf_key, Poseidon3(issuerId, expiresAt, 0))`.

## Deferred (next steps)

1. **Anonymity-set fixture** — a multi-credential verified-humans tree (extend the eligibility
   fixture generator; leaf = `key = C, value = 1`), to prove membership in a real set of N humans.
2. **UltraHonk verifier** export (`bb ... --oracle_hash keccak`) + the on-chain **redeem entrypoint**
   contract (verify + freshness + permission + consume + write leaf), wired as the
   `ClaimsSMTRegistry.redeemer`. Part A = a `VerifiedHumansTree` (another `ClaimsSMTRegistry`) the
   provider gate writes `C` into.

## Note

`TREE_DEPTH = 20` (matches the eligibility circuit + on-chain SMT). Credential leaf value = 1.
Archived `membership_proof/` and `eligibility_proof/` are untouched.
