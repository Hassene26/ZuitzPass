// =============================================================================
// ZuitzPass — Circuit B: Issuance binding (private redeem)
// =============================================================================
//
// Phase-3 strong private binding (contracts/PHASE3_UNLINKABLE_DESIGN.md §4/§4.1).
// After a provider gate verifies a human (Part A) and the human inserts a credential
// commitment `C = Poseidon2(secret, r)` into the per-provider verified-humans tree,
// this circuit lets them privately REDEEM that credential into a claim leaf on their
// master identity — revealing neither `C`, the provider nullifier, nor `idc`.
//
// Proves, in zero knowledge, that the prover:
//   1. Knows (secret, r) opening SOME leaf `C` in the verified-humans tree at `cred_root`
//      (membership, not revealing which `C` -> anonymity set = all Part-A humans).
//   2. Correctly derived the opaque claims-SMT key `leaf_key = Poseidon2(idc, claim_type)`
//      for their OWN identity `idc = Poseidon2(secret, 0)`.
//   3. Correctly derived a single-use `redeem_nullifier = Poseidon2(r, claim_type)`.
//
// -----------------------------------------------------------------------------
// PUBLIC INPUT INTERFACE (contract with the redeem entrypoint) — order matters:
//   [0] cred_root        : Field — verified-humans root (entrypoint checks freshness)
//   [1] claim_type       : Field — claim being minted (keccak(name) mod p); binds leaf_key
//   [2] leaf_key         : Field — Poseidon2(idc, claim_type); the opaque key to write
//   [3] redeem_nullifier : Field — Poseidon2(r, claim_type); consume once per (credential, type)
//
// Private witness (never leaves the device): secret, r, siblings[TREE_DEPTH].
//
// Reuses the archived/Circuit-A SMT gadget (`compute_root`) verbatim. Verified-humans leaf:
// key = C, value = 1, leaf_hash = Poseidon3(C, 1, 1).
// =============================================================================

use poseidon::poseidon::bn254;

global TREE_DEPTH: u32 = 20;
// Membership marker stored as the verified-humans leaf value (Part A writes value = 1).
global CRED_VALUE: Field = 1;

// idc = Poseidon2(secret, 0) — master identity commitment (never revealed).
fn compute_identity(secret: Field) -> Field {
    bn254::hash_2([secret, 0])
}

// Credential commitment inserted in Part A.
fn compute_commitment(secret: Field, r: Field) -> Field {
    bn254::hash_2([secret, r])
}

// Claims-SMT key for (identity, claimType).
fn compute_leaf_key(idc: Field, claim_type: Field) -> Field {
    bn254::hash_2([idc, claim_type])
}

// Single-use redeem nullifier, unique per (credential blinding, claimType), hides C and idc.
fn compute_redeem_nullifier(r: Field, claim_type: Field) -> Field {
    bn254::hash_2([r, claim_type])
}

// Verified-humans leaf node hash: Poseidon3(key = C, value = 1, leaf-marker = 1).
fn compute_cred_leaf_hash(commitment: Field) -> Field {
    bn254::hash_3([commitment, CRED_VALUE, 1])
}

// dl-solarity SMT root reconstruction — identical gadget to Circuit A / the archived circuit.
fn compute_root(leaf_hash: Field, siblings: [Field; TREE_DEPTH], leaf_key: Field) -> Field {
    let key_bits: [bool; 254] = leaf_key.to_le_bits();
    let mut current = leaf_hash;
    let mut started = false;

    for i in 0..TREE_DEPTH {
        let s_index = TREE_DEPTH - 1 - i;
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
    r: Field,
    siblings: [Field; TREE_DEPTH],
    // --- public inputs (see interface above) ---
    cred_root: pub Field,
    claim_type: pub Field,
    leaf_key: pub Field,
    redeem_nullifier: pub Field,
) {
    // 1. The prover owns a credential C that is a member of the verified-humans tree.
    let commitment = compute_commitment(secret, r);
    let cred_leaf_hash = compute_cred_leaf_hash(commitment);
    let computed_root = compute_root(cred_leaf_hash, siblings, commitment);
    assert(computed_root == cred_root);

    // 2. The claims-SMT key is this identity's key for `claim_type` (binds write to same secret).
    let idc = compute_identity(secret);
    assert(leaf_key == compute_leaf_key(idc, claim_type));

    // 3. The redeem nullifier is honestly derived (single-use per credential + type).
    assert(redeem_nullifier == compute_redeem_nullifier(r, claim_type));
}

// =============================================================================
// Tests — derive public inputs from the witness with the circuit's own helpers.
// Single-leaf credential trees (all-zero siblings => cred_root = leaf hash) exercise
// every path; a real anonymity-set fixture (many credentials) comes from the generator.
// =============================================================================

global TEST_CLAIM: Field = 0x554e495155455f48554d414e; // "UNIQUE_HUMAN"

fn zero_siblings() -> [Field; TREE_DEPTH] {
    [0; TREE_DEPTH]
}

fn single_cred_root(secret: Field, r: Field) -> Field {
    let c = compute_commitment(secret, r);
    compute_root(compute_cred_leaf_hash(c), zero_siblings(), c)
}

#[test]
fn test_redeem_happy_path() {
    let secret: Field = 424242;
    let r: Field = 987654321;

    let cred_root = single_cred_root(secret, r);
    let idc = compute_identity(secret);
    let leaf_key = compute_leaf_key(idc, TEST_CLAIM);
    let redeem_nullifier = compute_redeem_nullifier(r, TEST_CLAIM);

    main(secret, r, zero_siblings(), cred_root, TEST_CLAIM, leaf_key, redeem_nullifier);
}

// Wrong credential root (prover not a member) must reject.
#[test(should_fail)]
fn test_bad_cred_root_rejected() {
    let secret: Field = 424242;
    let r: Field = 987654321;
    let idc = compute_identity(secret);
    let leaf_key = compute_leaf_key(idc, TEST_CLAIM);
    let redeem_nullifier = compute_redeem_nullifier(r, TEST_CLAIM);

    main(secret, r, zero_siblings(), 0xDEAD, TEST_CLAIM, leaf_key, redeem_nullifier);
}

// leaf_key must bind to idc + claim_type (can't write to someone else's identity).
#[test(should_fail)]
fn test_wrong_leaf_key_rejected() {
    let secret: Field = 424242;
    let r: Field = 987654321;
    let cred_root = single_cred_root(secret, r);
    let redeem_nullifier = compute_redeem_nullifier(r, TEST_CLAIM);

    main(secret, r, zero_siblings(), cred_root, TEST_CLAIM, 0x1234, redeem_nullifier);
}

// redeem_nullifier must bind to r + claim_type (no forged single-use tag).
#[test(should_fail)]
fn test_wrong_redeem_nullifier_rejected() {
    let secret: Field = 424242;
    let r: Field = 987654321;
    let cred_root = single_cred_root(secret, r);
    let idc = compute_identity(secret);
    let leaf_key = compute_leaf_key(idc, TEST_CLAIM);

    main(secret, r, zero_siblings(), cred_root, TEST_CLAIM, leaf_key, 0x5678);
}
