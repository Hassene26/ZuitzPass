# SMT fixture generator

Generates a **real** membership fixture from dl-solarity's `SparseMerkleTree` (the lib
ERC-7812 uses), with Poseidon hashers, so we can validate that Circuit 1's `compute_root`
reproduces the on-chain root. This closes "Check 2" in
`membership_proof/CIRCUIT1_ISOLATED_KEY_NOTE.md`.

## Install the extra dependencies

```bash
cd contracts
forge install dl-solarity/solidity-lib
forge install privacy-scaling-explorations/poseidon-solidity
```

These map (see `foundry.toml`):
- `@solarity/solidity-lib/` → `lib/solidity-lib/contracts/`
- `poseidon-solidity/`      → `lib/poseidon-solidity/contracts/`

> Version note: dl-solarity's `SparseMerkleTree` API (type `Bytes32SMT`, and
> `initialize` / `setHashers` / `add` / `getProof` / `getRoot`) is version-sensitive. If
> `SmtFixtureWrapper.sol` fails to compile, check the installed version and adjust those
> calls. The poseidon-solidity `PoseidonT3` / `PoseidonT4` libraries are circomlib-
> compatible (they match Noir's `bn254::hash_2` / `hash_3`, confirmed via the
> `print_poseidon_2` cross-check).

## Run

```bash
cd contracts
forge script script/GenerateSmtFixture.s.sol:GenerateSmtFixture -vvv
```

This prints a ready-to-paste `Prover.toml` block and writes `./smt_fixture.json`.

## Validate the circuit against it

1. Copy the printed `secret / value / root / nullifier / session_binding / registrar /
   siblings` lines into `membership_proof/Prover.toml`.
2. In `membership_proof/`:
   ```bash
   nargo execute
   ```
3. **Success** → `compute_root` reproduces the real SMT root → Check 2 done.
   **Failure on the root assertion** → the mismatch is one of:
   - tree **depth** (fixed 20 vs the SMT's actual/variable depth),
   - **sibling array ordering** (root-first vs leaf-first),
   - **bit→direction** mapping,
   - leaf/empty-node handling.
   Adjust `compute_root` in `membership_proof/src/main.nr` and re-run until it matches.

## What the generator mirrors (must equal the circuit)

```
commitment = Poseidon2(secret, 0)
leaf_key   = Poseidon2(registrar, commitment)      // getIsolatedKey
nullifier  = Poseidon2(secret, APP_CONTEXT)        // APP_CONTEXT = "ZUITZERLAND"
leaf_hash  = Poseidon3(leaf_key, value, 1)         // done by the SMT on add()
```
