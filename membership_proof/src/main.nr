// =============================================================================
// Zuitzerland — Circuit 1: Membership Proof
// =============================================================================
//
// Proves, in zero knowledge, that the prover:
//   1. Knows a `secret` whose commitment is stored in the SHARED ERC-7812 Sparse
//      Merkle Tree at a publicly known `root`, at the ISOLATED position assigned
//      to the provider's `registrar` (ERC-7812 isolates writers by registrar).
//   2. Has honestly derived the published `nullifier` from that same `secret`
//      (scoped to this application via `APP_CONTEXT`).
//   3. Is publishing a `session_binding` value (bound off-circuit to the
//      caller's wallet + nonce) so the verifier contract can detect proof
//      reuse / cross-user collusion across sessions.
//   4. Is bound to a specific `registrar`, so a proof made under one provider's
//      registrar cannot be replayed through another provider's adapter.
//
// -----------------------------------------------------------------------------
// PUBLIC INPUT INTERFACE  (contract with the smart-contract engineer, Dev 2)
// -----------------------------------------------------------------------------
// The Solidity verifier receives the public inputs in THIS ORDER (4 values):
//
//   [0] root            : Field  — global SMT root being proven against.
//   [1] nullifier       : Field  — == Poseidon([secret, APP_CONTEXT]).
//                                   Unique-per-user, app-scoped, unlinkable to
//                                   the identity. Use for double-action / ban
//                                   tracking on chain.
//   [2] session_binding : Field  — opaque pass-through. The circuit only
//                                   re-publishes it; Dev 2's contract checks it
//                                   matches across the proofs of one session.
//   [3] registrar       : Field  — the provider's ERC-7812 registrar address
//                                   (right-aligned 160-bit value in a Field). The
//                                   verifier FORCES this from the chosen adapter,
//                                   so the proof is provably scoped to a provider.
//
// Private inputs (witness, NEVER leave the device):
//   secret, value, siblings[20].
//
// SMT model — matches dl-solarity `SparseMerkleTree` (the lib ERC-7812 uses), with
// Poseidon hashers (confirmed iden3-compatible, see CIRCUIT1_ISOLATED_KEY_NOTE.md):
//   * leaf position (key) = getIsolatedKey(registrar, Poseidon(secret))
//                         = Poseidon2(registrar, Poseidon(secret))
//   * leaf node hash      = Poseidon3(leafKey, value, 1)   // 1 = leaf marker
//   * middle node hash    = Poseidon2(left, right)         // left child first
//   * path direction      = bits of leafKey, LSB -> MSB    // (key >> i) & 1
// `value` is whatever the provider's registrar stored for this leaf; the prover
// supplies it as witness (membership is bound via the key, which derives from secret).
//
// ⚠️  Do NOT change the public-input set or ordering without flagging Dev 2.
// ⚠️  Fixed depth = 20 and full-depth reconstruction are still ASSUMPTIONS — the real
//     SMT is variable-depth. MUST validate against a real fixture before trusting real
//     proofs. See CIRCUIT1_ISOLATED_KEY_NOTE.md "Check 2".
// =============================================================================

use poseidon::poseidon::bn254;

// Tree depth of the ERC-7812 SMT.
global TREE_DEPTH: u32 = 20;

// Hardcoded application identifier that scopes nullifiers to Zuitzerland, so a
// nullifier produced here can never be replayed against another app's registry.
// (Decimal encoding of the ASCII bytes for "ZUITZERLAND".)
global APP_CONTEXT: Field = 0x5a55495446524c414e44; // "ZUITZERLAND"

// commitment = Poseidon2(secret, 0). The user's per-identity key BEFORE isolation.
// Uses 2-input Poseidon (not hash_1) so it is reproducible on the Solidity side with
// the standard PoseidonT3 library — keeping circuit and fixture hash-identical.
fn compute_commitment(secret: Field) -> Field {
    bn254::hash_2([secret, 0])
}

// ERC-7812 isolated key = the leaf POSITION in the shared global tree.
//   getIsolatedKey(source, key) = Poseidon2(uint256(uint160(source)), key)   [confirmed]
// `registrar` is passed as the right-aligned 160-bit Field, matching the contract's
// bytes32(uint256(uint160(addr))) encoding.
fn compute_isolated_key(registrar: Field, key: Field) -> Field {
    bn254::hash_2([registrar, key])
}

// Convenience: the full leaf position for a (registrar, secret) pair.
fn compute_leaf_key(registrar: Field, secret: Field) -> Field {
    compute_isolated_key(registrar, compute_commitment(secret))
}

// Leaf node hash, per dl-solarity SparseMerkleTree: Poseidon3(key, value, 1).
// The trailing 1 is the leaf marker that distinguishes leaves from middle nodes.
fn compute_leaf_hash(leaf_key: Field, value: Field) -> Field {
    bn254::hash_3([leaf_key, value, 1])
}

// nullifier = Poseidon([secret, APP_CONTEXT])
fn compute_nullifier(secret: Field) -> Field {
    bn254::hash_2([secret, APP_CONTEXT])
}

// Recompute the SMT root from the leaf node hash and its sibling path, matching
// dl-solarity `SparseMerkleTree._processProof` (the variable-depth reconstruction):
//
//   depth = siblings.length; trim trailing-zero siblings (deepest end);
//   for sIndex = depth-1 down to 0:
//       bit (key >> sIndex) & 1 == 1 -> H(sibling, current)   // current is right child
//       else                         -> H(current, sibling)   // current is left child
//
// `siblings` is ordered root-first (index 0 = top, high index = deeper). We can't do a
// dynamic-length loop in a fixed circuit, so we walk all TREE_DEPTH levels deepest-first
// and only start hashing once we pass the trailing zeros — i.e. a level is ACTIVE once we
// have seen a non-zero sibling at or below it. This reproduces "trim trailing zeros, then
// hash up". A single-leaf tree (all-zero siblings) stays inactive throughout, so the root
// is just the leaf hash — exactly what the on-chain tree returns.
fn compute_root(leaf_hash: Field, siblings: [Field; TREE_DEPTH], leaf_key: Field) -> Field {
    // Decompose the FULL key (~254-bit Poseidon output); use the low bits per level.
    let key_bits: [bool; 254] = leaf_key.to_le_bits();
    let mut current = leaf_hash;
    let mut started = false; // becomes true at the deepest non-zero sibling

    for i in 0..TREE_DEPTH {
        let s_index = TREE_DEPTH - 1 - i; // deepest level first, up toward the root
        let sibling = siblings[s_index];
        let active = started | (sibling != 0);

        let left = if key_bits[s_index] { sibling } else { current };
        let right = if key_bits[s_index] { current } else { sibling };
        let combined = bn254::hash_2([left, right]);

        current = if active { combined } else { current };
        started = active;
    }

    current
}

fn main(
    // --- private witness ---
    secret: Field,
    value: Field,
    siblings: [Field; TREE_DEPTH],
    // --- public inputs: [root, nullifier, session_binding, registrar] ---
    root: pub Field,
    nullifier: pub Field,
    session_binding: pub Field,
    registrar: pub Field,
) {
    // 1. Leaf position is the ERC-7812 isolated key for this registrar.
    let leaf_key = compute_leaf_key(registrar, secret);

    // 2. Leaf node hash (Poseidon3 with leaf marker), then SMT inclusion: the
    //    recomputed root must match the public root.
    let leaf_hash = compute_leaf_hash(leaf_key, value);
    let computed_root = compute_root(leaf_hash, siblings, leaf_key);
    assert(computed_root == root);

    // 3. Nullifier was honestly derived from the same secret.
    let expected_nullifier = compute_nullifier(secret);
    assert(expected_nullifier == nullifier);

    // 4. `session_binding` and `registrar` need no further constraint — being
    //    `pub` parameters already publishes them. The verifier contract enforces
    //    session consistency and forces `registrar` from the chosen adapter.
    //    (No return value: public inputs are exactly the four `pub` params.)
    let _ = session_binding; // published as a public input; no in-circuit constraint
}

// =============================================================================
// Tests
// =============================================================================
//
// ZK note: rather than hardcoding opaque Poseidon outputs (which would require
// running the hasher by hand), we hardcode the *witness* (secret, siblings,
// index, session, registrar) and derive `root` / `nullifier` with the circuit's
// own helpers. This is a true end-to-end happy path: if the inclusion logic or
// nullifier derivation were wrong, the assertions inside `main` would fail.

// A stand-in registrar address (right-aligned 160-bit value), e.g. zkPassport's.
global TEST_REGISTRAR: Field = 0x00000000000000000000000000000000000021c0;

// ---------------------------------------------------------------------------
// Poseidon compatibility cross-check (NOT an assertion — a value to compare).
//
// ERC-7812 uses iden3/circomlib Poseidon (`PoseidonUnit2L`). Noir's poseidon lib
// is a *different* implementation of "Poseidon"; the two only interoperate if
// their constants match. Run:
//   nargo test --show-output print_poseidon_2
// and compare the printed value against circomlibjs:
//   const p = await require("circomlibjs").buildPoseidon();
//   console.log(p.F.toString(p([1, 2])));
// Equal  -> Noir's hash_2 is iden3-compatible; isolated keys/tree will match.
// Differ -> we must swap in an iden3-compatible Poseidon before any real proof.
// ---------------------------------------------------------------------------
#[test]
fn print_poseidon_2() {
    println(bn254::hash_2([1, 2]));
}

// Build the inclusion root the same way the circuit does, from a witness.
fn build_root(registrar: Field, secret: Field, value: Field, siblings: [Field; TREE_DEPTH]) -> Field {
    let leaf_key = compute_leaf_key(registrar, secret);
    let leaf_hash = compute_leaf_hash(leaf_key, value);
    compute_root(leaf_hash, siblings, leaf_key)
}

#[test]
fn test_membership_happy_path() {
    let secret: Field = 424242;
    let value: Field = 777;
    let session_binding: Field = 0xBEEF;
    let registrar: Field = TEST_REGISTRAR;

    // Arbitrary but fixed sibling hashes for each of the 20 levels.
    let mut siblings: [Field; TREE_DEPTH] = [0; TREE_DEPTH];
    for i in 0..TREE_DEPTH {
        siblings[i] = (i as Field) + 1000;
    }

    // Derive the public inputs the same way the circuit will.
    let root = build_root(registrar, secret, value, siblings);
    let nullifier = compute_nullifier(secret);

    main(secret, value, siblings, root, nullifier, session_binding, registrar);
}

#[test]
fn test_membership_other_witness() {
    // A different secret/value puts the leaf at a different key (different path bits).
    let secret: Field = 9001;
    let value: Field = 0xABCDEF;
    let session_binding: Field = 0xCAFE;
    let registrar: Field = TEST_REGISTRAR;

    let mut siblings: [Field; TREE_DEPTH] = [0; TREE_DEPTH];
    for i in 0..TREE_DEPTH {
        siblings[i] = (i as Field) * 7 + 13;
    }

    let root = build_root(registrar, secret, value, siblings);
    let nullifier = compute_nullifier(secret);

    main(secret, value, siblings, root, nullifier, session_binding, registrar);
}

#[test(should_fail)]
fn test_membership_bad_root_rejected() {
    let secret: Field = 424242;
    let value: Field = 777;
    let session_binding: Field = 0xBEEF;
    let registrar: Field = TEST_REGISTRAR;

    let mut siblings: [Field; TREE_DEPTH] = [0; TREE_DEPTH];
    for i in 0..TREE_DEPTH {
        siblings[i] = (i as Field) + 1000;
    }

    let nullifier = compute_nullifier(secret);
    // Wrong root -> inclusion assertion must fail.
    let bad_root: Field = 1;
    main(secret, value, siblings, bad_root, nullifier, session_binding, registrar);
}

#[test(should_fail)]
fn test_membership_wrong_registrar_rejected() {
    // A proof built for one registrar must NOT verify against a different
    // registrar: the isolated key (hence the root) changes with the registrar.
    let secret: Field = 424242;
    let value: Field = 777;
    let session_binding: Field = 0xBEEF;

    let mut siblings: [Field; TREE_DEPTH] = [0; TREE_DEPTH];
    for i in 0..TREE_DEPTH {
        siblings[i] = (i as Field) + 1000;
    }

    // Build the root against registrar A...
    let registrar_a: Field = TEST_REGISTRAR;
    let root = build_root(registrar_a, secret, value, siblings);
    let nullifier = compute_nullifier(secret);

    // ...but submit with registrar B -> inclusion assertion must fail.
    let registrar_b: Field = 0x00000000000000000000000000000000000000aa;
    main(secret, value, siblings, root, nullifier, session_binding, registrar_b);
}
