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

## Required change to Circuit 1

1. **Add `registrar` as an input** (the provider's registrar address, as a `Field`).
2. **Derive the isolated key** and use it as the leaf key for the Merkle path:

   ```
   leaf_key = poseidon([registrar, Poseidon(secret)])   // match ERC-7812's getIsolatedKey
   ```

   ⚠️ Confirm the EXACT hashing scheme `getIsolatedKey` uses on the target deployment
   (hash function, field encoding of the address, argument order). Match it bit-for-bit,
   or inclusion proofs won't verify. Pull it from the deployed registry / Rarimo's
   implementation rather than assuming.

3. **Expose `registrar` as a PUBLIC input.** The on-chain verifier forces the chosen
   provider-adapter's registrar into the public inputs, so the proof is provably scoped
   to that provider. This is what makes per-provider root-validity windows non-gameable.

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
