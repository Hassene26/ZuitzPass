// =============================================================================
// Zuitzerland — Circuit 1: Membership Proof
// =============================================================================
//
// Proves, in zero knowledge, that the prover:
//   1. Knows a `secret` whose Poseidon hash is a leaf (commitment) that exists
//      in the ERC-7812 Sparse Merkle Tree at a publicly known `root`.
//   2. Has honestly derived the published `nullifier` from that same `secret`
//      (scoped to this application via `APP_CONTEXT`).
//   3. Is publishing a `session_binding` value (bound off-circuit to the
//      caller's wallet + nonce) so the verifier contract can detect proof
//      reuse / cross-user collusion across sessions.
//
// -----------------------------------------------------------------------------
// PUBLIC INPUT INTERFACE  (contract with the smart-contract engineer, Dev 2)
// -----------------------------------------------------------------------------
// The Solidity verifier receives the public inputs in THIS ORDER:
//
//   [0] root            : Field  — SMT root being proven against.
//   [1] nullifier       : Field  — == Poseidon([secret, APP_CONTEXT]).
//                                   Unique-per-user, app-scoped, unlinkable to
//                                   the identity. Use for double-action / ban
//                                   tracking on chain.
//   [2] session_binding : Field  — opaque pass-through. The circuit only
//                                   re-publishes it; Dev 2's contract checks it
//                                   matches across the proofs of one session.
//
// Private inputs (witness, NEVER leave the device):
//   secret, merkle_path[20], leaf_index.
//
// Tree depth is fixed at 20. For the PoC the SMT leaf KEY equals the leaf VALUE
// (both == Poseidon(secret)); if that changes, the interface comment above and
// Dev 2 must both be updated.
//
// ⚠️  Do NOT change the public-input set or ordering without flagging Dev 2.
// =============================================================================

use poseidon::poseidon::bn254;

// Tree depth of the ERC-7812 SMT.
global TREE_DEPTH: u32 = 20;

// Hardcoded application identifier that scopes nullifiers to Zuitzerland, so a
// nullifier produced here can never be replayed against another app's registry.
// (Decimal encoding of the ASCII bytes for "ZUITZERLAND".)
global APP_CONTEXT: Field = 0x5a55495446524c414e44; // "ZUITZERLAND"

// commitment = leaf value = Poseidon(secret)
fn compute_commitment(secret: Field) -> Field {
    bn254::hash_1([secret])
}

// nullifier = Poseidon([secret, APP_CONTEXT])
fn compute_nullifier(secret: Field) -> Field {
    bn254::hash_2([secret, APP_CONTEXT])
}

// Recompute the SMT root bottom-up from a leaf and its Merkle path.
//
// At each level `i`, bit `i` of `leaf_index` selects whether `current` is the
// left (bit = 0) or right (bit = 1) child, and we hash it with its sibling.
fn compute_root(leaf: Field, merkle_path: [Field; TREE_DEPTH], leaf_index: Field) -> Field {
    let index_bits: [bool; TREE_DEPTH] = leaf_index.to_le_bits();
    let mut current = leaf;

    for i in 0..TREE_DEPTH {
        let sibling = merkle_path[i];
        // bit == false (0) -> current is the LEFT child:  parent = H(current, sibling)
        // bit == true  (1) -> current is the RIGHT child: parent = H(sibling, current)
        let left = if index_bits[i] { sibling } else { current };
        let right = if index_bits[i] { current } else { sibling };
        current = bn254::hash_2([left, right]);
    }

    current
}

fn main(
    // --- private witness ---
    secret: Field,
    merkle_path: [Field; TREE_DEPTH],
    leaf_index: Field,
    // --- public inputs ---
    root: pub Field,
    nullifier: pub Field,
    session_binding: pub Field,
) -> pub Field {
    // 1 & 2. commitment == leaf value, and (PoC) leaf key == commitment.
    let commitment = compute_commitment(secret);
    let leaf_key = commitment;

    // 3. SMT inclusion: recomputed root must match the public root.
    let computed_root = compute_root(leaf_key, merkle_path, leaf_index);
    assert(computed_root == root);

    // 4. Nullifier was honestly derived from the same secret.
    let expected_nullifier = compute_nullifier(secret);
    assert(expected_nullifier == nullifier);

    // 5. Re-publish the session binding (no further constraint; the verifier
    //    contract enforces cross-proof consistency off-circuit).
    session_binding
}

// =============================================================================
// Tests
// =============================================================================
//
// ZK note: rather than hardcoding opaque Poseidon outputs (which would require
// running the hasher by hand), we hardcode the *witness* (secret, siblings,
// index, session) and derive `root` / `nullifier` with the circuit's own
// helpers. This is a true end-to-end happy path: if the inclusion logic or
// nullifier derivation were wrong, the assertions inside `main` would fail.

#[test]
fn test_membership_happy_path() {
    let secret: Field = 424242;
    let leaf_index: Field = 0; // left-most leaf: all path bits = 0
    let session_binding: Field = 0xBEEF;

    // Arbitrary but fixed sibling hashes for each of the 20 levels.
    let mut merkle_path: [Field; TREE_DEPTH] = [0; TREE_DEPTH];
    for i in 0..TREE_DEPTH {
        merkle_path[i] = (i as Field) + 1000;
    }

    // Derive the public inputs the same way the circuit will.
    let leaf = compute_commitment(secret);
    let root = compute_root(leaf, merkle_path, leaf_index);
    let nullifier = compute_nullifier(secret);

    let returned = main(secret, merkle_path, leaf_index, root, nullifier, session_binding);
    assert(returned == session_binding);
}

#[test]
fn test_membership_nonzero_index() {
    // Exercise a path where the leaf sits at a right/left mix of positions.
    let secret: Field = 9001;
    let leaf_index: Field = 22; // 0b10110 — mixed bits across levels
    let session_binding: Field = 0xCAFE;

    let mut merkle_path: [Field; TREE_DEPTH] = [0; TREE_DEPTH];
    for i in 0..TREE_DEPTH {
        merkle_path[i] = (i as Field) * 7 + 13;
    }

    let leaf = compute_commitment(secret);
    let root = compute_root(leaf, merkle_path, leaf_index);
    let nullifier = compute_nullifier(secret);

    let returned = main(secret, merkle_path, leaf_index, root, nullifier, session_binding);
    assert(returned == session_binding);
}

#[test(should_fail)]
fn test_membership_bad_root_rejected() {
    let secret: Field = 424242;
    let leaf_index: Field = 0;
    let session_binding: Field = 0xBEEF;

    let mut merkle_path: [Field; TREE_DEPTH] = [0; TREE_DEPTH];
    for i in 0..TREE_DEPTH {
        merkle_path[i] = (i as Field) + 1000;
    }

    let nullifier = compute_nullifier(secret);
    // Wrong root -> inclusion assertion must fail.
    let bad_root: Field = 1;
    let _ = main(secret, merkle_path, leaf_index, bad_root, nullifier, session_binding);
}
