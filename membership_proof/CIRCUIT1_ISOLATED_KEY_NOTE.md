# Circuit 1 — coordination note: ERC-7812 isolated keys & the new `registrar` public input

**Status:** action needed on Circuit 1 before real end-to-end works.
**Source of truth:** ERC-7812 (singleton EvidenceRegistry) + the smart-contract refactor
in `contracts/` (see `ARCHITECTURE.md`).

## What we learned

ERC-7812 is **one shared singleton registry** (`0x781246D2256dc0C1d8357c9dDc1eEe926a9c7812`)
with **one global Sparse Merkle Tree** and **one global root** for *all* providers
(Rarimo, zkPassport, …). Providers do **not** get separate trees.

Isolation between providers is done by the registry itself: when a provider's
**Registrar** contract calls `addStatement(key, value)`, the registry stores the leaf
not at `key` but at:

```
isolatedKey = getIsolatedKey(registrarAddress, key)   // ≈ hash(registrarAddress, key)
```

where `registrarAddress` is the `msg.sender` (the registrar). So **the position of your
leaf in the global tree depends on which provider's registrar wrote it.**

## Why this breaks the current circuit

Circuit 1 currently computes:

```
leaf_key = Poseidon(secret)
```

But the real leaf is at `getIsolatedKey(registrar, Poseidon(secret))`. So a Merkle path
fetched from the real registry goes to the **isolated** position, and the current circuit
would recompute the root from the wrong key → inclusion check fails.

## Required change to Circuit 1  — DONE

1. [x] **Add `registrar` as a public input** (provider registrar address, as a `Field`).
2. [x] **Derive the isolated key** and use it as the leaf key for the Merkle path.
3. [x] **Expose `registrar` publicly** so the verifier can force the chosen adapter's
       registrar in — making per-provider windows non-gameable.

## getIsolatedKey — CONFIRMED scheme (from EIP-7812 reference impl)

```solidity
function getIsolatedKey(address source_, bytes32 key_) public pure returns (bytes32) {
    return PoseidonUnit2L.poseidon([bytes32(uint256(uint160(source_))), key_]);
}
```

- **Poseidon, 2 inputs.** Address FIRST (cast `uint160 → uint256 → bytes32`), key second.
- Our circuit matches this **structure + encoding**: `compute_isolated_key(registrar, key)
  = hash_2([registrar, key])`, with `registrar` the right-aligned 160-bit Field — the same
  encoding the contract uses (`bytes32(uint256(uint160(addr)))`).

⚠️ **Formula confirmed ≠ bytes confirmed.** Two open compatibility checks remain before a
real proof will verify:

### Check 1 (critical): Poseidon parameter compatibility — ✅ PASSED (2026-06-07)
`PoseidonUnit2L` is **iden3/circomlib** Poseidon. Noir's `poseidon` lib is a *different*
implementation; "Poseidon" is a parameterized family (round constants, MDS), so the two
could disagree on identical inputs.

Cross-check run via the `print_poseidon_2` test:
```
nargo test --show-output print_poseidon_2
-> 0x115cc0f5e7d690413df64c6b9662e9cf2a3617f2743245519e19607a4417189a
```
This equals the canonical circomlib `poseidon([1,2])` test vector
(`7853200120776062878684798364095072458815029376092732009249414926327459813530`).
**Conclusion: Noir's `bn254::hash_2` IS iden3/circomlib-compatible.** The isolated-key
derivation is byte-correct as written, and `hash_2`/`hash_3` node hashing will match the
real registry's Poseidon.

### Check 2: SMT node-hashing scheme — structure implemented, fixture pending
Source read: dl-solarity `SparseMerkleTree`
(`contracts/libs/data-structures/SparseMerkleTree.sol`). Confirmed recipe, now
implemented in `compute_root` / `compute_leaf_hash`:
- **leaf node** = `hash3(key, value, 1)` — `1` is the leaf marker; `key` = isolated key.
- **middle node** = `hash2(left, right)` — left child first.
- **direction** = bits of the **leaf key**, LSB→MSB (`(key >> i) & 1`); bit 1 → current is
  the right child.
- **hashers**: library defaults to keccak but ERC-7812 sets **Poseidon** via `setHashers()`
  → matches our `hash2`/`hash3` (Check 1 passed).

Circuit witness updated accordingly: `secret`, `value`, `siblings[20]` (the old separate
`leaf_index` is gone — position now derives from the key, as in the real SMT).

**Variable-depth reconstruction — now implemented from `_processProof`.**
dl-solarity computes depth by trimming TRAILING-ZERO siblings, then hashes from that depth
up to the root (siblings root-first; bit `(key >> sIndex) & 1` chooses left/right). Our
`compute_root` reproduces this with a fixed deepest-first loop and a `started` flag that
activates at the deepest non-zero sibling — so a single-leaf tree (all-zero siblings) yields
`root = leaf_hash`, matching the chain.

**Validation status:**
- A single-leaf fixture (all-zero siblings) validates the leaf hash + degenerate path.
- The generator now also inserts decoy leaves so the proof has a **non-zero path**, which
  validates sibling ordering + direction. Run `forge script ... GenerateSmtFixture`, paste
  into `Prover.toml`, `nargo execute`. Success on a non-trivial path ⇒ Check 2 closed.

Remaining real-integration caveat: `value` is whatever each provider's registrar actually
stored for the leaf — the client must supply the real one. The fixture uses a placeholder.

## New locked public-input interface (contract ↔ circuit)

Order is now **4** values (was 3):

```
[ root, nullifier, sessionBinding, registrar ]
```

- `root` — global SMT root proven against
- `nullifier` — `Poseidon(secret, app_context)` (unchanged for now; see §4 of ARCHITECTURE
  for the future per-action `actionId` extension)
- `sessionBinding` — pass-through (`hash(wallet, nonce)`)
- `registrar` — provider registrar address, as a `Field` (the verifier sets this from the
  adapter; the client must prove with the same value)

The Solidity side already passes input #3 as `bytes32(uint256(uint160(registrarAddress)))`.
The circuit must encode the address identically (right-aligned 160-bit value in a Field).

## Net
- **Contracts:** done — single registry, registrar-bound public input, per-provider window.
- **Circuit:** needs the isolated-key derivation + `registrar` public input above.
- **Client:** must fetch the Merkle path for the isolated key and feed `registrar` into the
  proof. Until the circuit lands this, the mock-based tests pass but a real proof will not
  verify against the real registry.
