# Zuitzerland — Circuit 1 (Membership Proof) — Handoff

## TL;DR

Circuit 1 is **done, tested, and compiled to a Solidity verifier.** It proves anonymous
membership in the ERC-7812 Sparse Merkle Tree (SMT) without revealing the user's identity.
The next person (smart-contract engineer, "Dev 2") builds the on-chain verification + governance
logic on top of the generated `Verifier.sol`.

---

## What this circuit proves

> *"I know a secret such that:*
> 1. *its Poseidon hash is a commitment that exists in the SMT at a known root,*
> 2. *the nullifier I publish was honestly derived from that same secret, and*
> 3. *the session binding I publish was honestly included (anti-replay / anti-collusion)."*

No identity, no secret, and no leaf position are ever revealed — only the three public inputs below.

---

## Public-input interface (THE CONTRACT — do not reorder)

The Solidity verifier receives public inputs in **exactly this order**:

| # | Name | Meaning |
|---|------|---------|
| 0 | `root` | SMT root the proof is checked against. |
| 1 | `nullifier` | `Poseidon([secret, APP_CONTEXT])`. App-scoped, unlinkable to identity. Use for double-action / ban tracking. |
| 2 | `session_binding` | Opaque pass-through (hash of wallet + nonce). Circuit only re-publishes it; the contract enforces consistency across a session's proofs. |

**Private inputs** (witness, never leave the device): `secret`, `merkle_path[20]`, `leaf_index`.

Key facts:
- Tree depth is fixed at **20**.
- `APP_CONTEXT` is a hardcoded constant = ASCII `"ZUITZERLAND"`, scoping nullifiers so they can't be replayed against other apps' registries.
- For the PoC, **leaf key == leaf value == `Poseidon(secret)`**. If that changes, this table and Dev 2 must both be updated.

> ⚠️ Changing the public-input set or order is a breaking change for Dev 2. Flag it explicitly.

---

## What was built

| File | Purpose |
|------|---------|
| `src/main.nr` | The circuit: commitment, SMT inclusion (bottom-up Poseidon), nullifier derivation, session pass-through. Includes a documented interface header + 3 tests. |
| `Nargo.toml` | Project config + `poseidon` v0.3.0 dependency. |
| `target/Verifier.sol` | **UltraHonk (ZK, Keccak oracle hash) Solidity verifier** — the artifact for Dev 2. |
| `target/vk` / `target/vk_hash` | Verification key + hash. |
| `target/membership_proof.json` | Compiled ACIR. |

### How it works internally
1. `commitment = Poseidon(secret)` — the leaf value.
2. `leaf_key = commitment` (PoC simplification).
3. SMT inclusion: walk 20 levels bottom-up. At level `i`, bit `i` of `leaf_index` picks
   left/right child; hash current node with its sibling via `Poseidon`. Final hash must equal `root`.
4. `nullifier == Poseidon([secret, APP_CONTEXT])` is asserted.
5. `session_binding` is returned as a public output (no constraint).

### Tests (all passing)
- `test_membership_happy_path` — left-most leaf, full end-to-end.
- `test_membership_nonzero_index` — mixed left/right path bits.
- `test_membership_bad_root_rejected` — `should_fail`; wrong root is rejected.

> Test design note: tests hardcode the *witness* and derive `root`/`nullifier` with the circuit's
> own helpers, so they're a genuine end-to-end check rather than asserting opaque hash constants.

---

## Toolchain (verified working)

Noir + Barretenberg (BB) are installed in **WSL Ubuntu only** (not Windows). This is a recent Noir
where Poseidon lives in an external library, not `std`.

```bash
cd /mnt/c/Users/MSI/Desktop/crypto/ZuitzPass/membership_proof

# Tests
nargo test --show-output

# Compile -> VK -> Solidity verifier
nargo compile
bb write_vk --oracle_hash keccak -b ./target/membership_proof.json -o ./target/
bb write_solidity_verifier -k ./target/vk -o ./target/Verifier.sol
```

Dependency pin (in `Nargo.toml`):
```toml
poseidon = { tag = "v0.3.0", git = "https://github.com/noir-lang/poseidon" }
```
Import is `use poseidon::poseidon::bn254;`. Note: `u1` is gone (use `bool`); no `0b` literals.

---

## What the next person can / should do

### Dev 2 — smart-contract engineer (immediate)
1. **Wire in `Verifier.sol`.** Deploy it and call `verify(proof, publicInputs)` with public inputs
   ordered `[root, nullifier, session_binding]`.
2. **Validate `root`** against the live ERC-7812 SMT root (don't trust a caller-supplied root blindly).
3. **Track `nullifier`** on-chain to enforce one-action-per-member / detect bans.
4. **Enforce `session_binding`** consistency across the proofs of a single session, and bind it to
   the calling wallet + nonce off-circuit.
5. **Wire governance:** banning/revocation = removing the commitment from the SMT, which makes the
   member's future proofs fail inclusion automatically.

### Circuit-side follow-ups (future / V2 — explicitly out of scope now)
- **Recursive proofs** (aggregating multiple memberships / providers) — flagged as V2.
- **Provider-specific logic** (Rarimo / zkPassport) — intentionally omitted; Circuit 1 is provider-agnostic.
- **Non-membership / exclusion proofs** if governance needs "prove you are NOT banned" semantics.
- **Decouple leaf key from leaf value** if the production SMT keys leaves differently than `Poseidon(secret)`.
- Decide whether the production verifier should be **ZK UltraHonk (current)** or non-ZK Honk, and lock
  the public-input encoding accordingly.

### Integration / testing
- Build a fixture generator (JS/TS or Rust) that produces real SMT paths + witnesses so Dev 2 can
  generate actual proofs against the deployed verifier, not just unit tests.
