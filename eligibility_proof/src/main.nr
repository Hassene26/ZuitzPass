// =============================================================================
// ZuitzPass — Circuit A: Eligibility (generalized membership)
// =============================================================================
//
// Phase-3 unlinkable statements (see contracts/PHASE3_UNLINKABLE_DESIGN.md §3).
// Generalizes the archived `membership_proof` from "one inclusion + one nullifier"
// to "a conjunction of claim inclusions + a per-app nullifier", so Alice can prove
// she satisfies a whole statement (allOf) with one local proof, revealing nothing
// but "eligible + a fresh nullifier for this app/context".
//
// Proves, in zero knowledge, that the prover:
//   1. Knows a master `secret`; identity commitment idc = Poseidon2(secret, 0).
//   2. For every ACTIVE required claim type, a valid, non-expired claim leaf exists
//      in the claims SMT at `root`, keyed Poseidon2(idc, claimType).
//   3. Honestly derived `nullifier = Poseidon3(secret, app_id, context_id)` —
//      unique per (identity, app, context), unlinkable across apps.
//
// -----------------------------------------------------------------------------
// PUBLIC INPUT INTERFACE (contract with the Solidity gate) — order matters:
//   [0] root         : Field — claims-SMT root proven against (gate checks freshness)
//   [1] nullifier    : Field — == Poseidon3(secret, app_id, context_id) (consume this)
//   [2] app_id       : Field — the consuming app's scope
//   [3] context_id   : Field — epoch / event instance / proposal
//   [4] now_ts       : u64   — current time; gate checks ~= block.timestamp
//   [5..5+MAX_CLAIMS] claim_types : [Field; MAX_CLAIMS] — the statement's required set
//                                   (0 = unused slot, skipped). Gate asserts these equal
//                                   the registered statement so proof-for-A can't pass B.
//   [5+MAX_CLAIMS] signal : Field — opaque binding (e.g. recipient); published, no constraint
//
// Private witness (never leaves the device):
//   secret, issuer_ids[MAX_CLAIMS], expires_ats[MAX_CLAIMS], siblings[MAX_CLAIMS][TREE_DEPTH]
//
// SMT model matches dl-solarity `SparseMerkleTree` with iden3-compatible Poseidon,
// identical to the archived circuit (leaf hash Poseidon3(key, value, 1), middle
// Poseidon2(left, right), variable-depth trailing-zero handling). Leaf keys drop the
// per-leaf ERC-7812 registrar term — isolation now lives at the root anchor (Model 2,
// see the spec §2). MUST validate against a real multi-leaf fixture before trusting
// real proofs (extend the SMT fixture generator to emit N coexisting leaves + paths).
// =============================================================================

use poseidon::poseidon::bn254;

global TREE_DEPTH: u32 = 20;
// Max required claim types per statement. Unused slots carry claim_type == 0 and are
// skipped. Bump this (and the fixture generator) if a statement needs more conjuncts.
global MAX_CLAIMS: u32 = 4;

// idc = Poseidon2(secret, 0) — the master identity commitment (never revealed).
fn compute_identity(secret: Field) -> Field {
    bn254::hash_2([secret, 0])
}

// Claims-SMT leaf position for (identity, claimType).
fn compute_leaf_key(idc: Field, claim_type: Field) -> Field {
    bn254::hash_2([idc, claim_type])
}

// Leaf value commits the claim's issuer + expiry (extensible with more fields later).
fn compute_leaf_value(issuer_id: Field, expires_at: Field) -> Field {
    bn254::hash_3([issuer_id, expires_at, 0])
}

// Leaf node hash, per dl-solarity: Poseidon3(key, value, 1). The trailing 1 is the leaf marker.
fn compute_leaf_hash(leaf_key: Field, value: Field) -> Field {
    bn254::hash_3([leaf_key, value, 1])
}

// nullifier = Poseidon3(secret, app_id, context_id) — app+context scoped, identity-hiding.
fn compute_nullifier(secret: Field, app_id: Field, context_id: Field) -> Field {
    bn254::hash_3([secret, app_id, context_id])
}

// Recompute the SMT root from a leaf hash + sibling path (dl-solarity `_processProof`,
// variable-depth). Identical to the archived circuit's gadget: walk deepest-first, only
// hashing once past the trailing zeros. All-zero siblings => single-leaf tree => root = leaf.
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
    issuer_ids: [Field; MAX_CLAIMS],
    expires_ats: [u64; MAX_CLAIMS],
    siblings: [[Field; TREE_DEPTH]; MAX_CLAIMS],
    // --- public inputs (see interface above) ---
    root: pub Field,
    nullifier: pub Field,
    app_id: pub Field,
    context_id: pub Field,
    now_ts: pub u64,
    claim_types: pub [Field; MAX_CLAIMS],
    signal: pub Field,
) {
    let idc = compute_identity(secret);

    for i in 0..MAX_CLAIMS {
        let claim_type = claim_types[i];
        let active = claim_type != 0; // slot in use?

        // Reconstruct this claim's leaf and its root.
        let leaf_key = compute_leaf_key(idc, claim_type);
        let value = compute_leaf_value(issuer_ids[i], expires_ats[i] as Field);
        let leaf_hash = compute_leaf_hash(leaf_key, value);
        let computed_root = compute_root(leaf_hash, siblings[i], leaf_key);

        // Active slots must be included under `root` ...
        assert(!active | (computed_root == root));
        // ... and not expired (0 = never expires).
        let not_expired = (expires_ats[i] == 0) | (expires_ats[i] > now_ts);
        assert(!active | not_expired);
    }

    // Nullifier honestly derived from the same secret, scoped to this app + context.
    assert(nullifier == compute_nullifier(secret, app_id, context_id));

    // `signal` is bound simply by being a public input (like the archived session_binding):
    // any tamper changes the proof's public inputs and invalidates it.
    let _ = signal;
}

// =============================================================================
// Tests — derive public inputs from the witness with the circuit's own helpers,
// so a happy path is a true end-to-end check. Multi-leaf-under-one-root proofs
// need the SMT fixture generator (N coexisting leaves); these cover the new logic
// (identity, keyed leaf, expiry, app nullifier, sentinel skip) with single-leaf trees.
// =============================================================================

global TEST_HUMAN: Field = 0x554e495155455f48554d414e; // "UNIQUE_HUMAN"
global TEST_APP: Field = 0x43414e4e4553; // "CANNES"
global TEST_CTX: Field = 202606;

fn zero_siblings() -> [Field; TREE_DEPTH] {
    [0; TREE_DEPTH]
}

// Root of a single-leaf tree (all-zero siblings) = the leaf hash itself.
fn single_leaf_root(secret: Field, claim_type: Field, issuer_id: Field, expires_at: u64) -> Field {
    let idc = compute_identity(secret);
    let leaf_key = compute_leaf_key(idc, claim_type);
    let value = compute_leaf_value(issuer_id, expires_at as Field);
    let leaf_hash = compute_leaf_hash(leaf_key, value);
    compute_root(leaf_hash, zero_siblings(), leaf_key)
}

// One active claim (slot 0), slots 1..MAX sentinel (claim_type 0, skipped).
#[test]
fn test_eligibility_single_claim() {
    let secret: Field = 424242;
    let issuer: Field = 0x1D;
    let expires: u64 = 2000000000; // ~2033
    let now: u64 = 1900000000;

    let mut issuer_ids: [Field; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut expires_ats: [u64; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut claim_types: [Field; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut siblings: [[Field; TREE_DEPTH]; MAX_CLAIMS] = [[0; TREE_DEPTH]; MAX_CLAIMS];

    claim_types[0] = TEST_HUMAN;
    issuer_ids[0] = issuer;
    expires_ats[0] = expires;
    siblings[0] = zero_siblings();

    let root = single_leaf_root(secret, TEST_HUMAN, issuer, expires);
    let nullifier = compute_nullifier(secret, TEST_APP, TEST_CTX);

    main(secret, issuer_ids, expires_ats, siblings, root, nullifier, TEST_APP, TEST_CTX, now, claim_types, 0xBEEF);
}

// Never-expires (expires_at = 0) is accepted even far in the future.
#[test]
fn test_never_expires() {
    let secret: Field = 7;
    let issuer: Field = 0x1D;
    let now: u64 = 4000000000;

    let mut issuer_ids: [Field; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut expires_ats: [u64; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut claim_types: [Field; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut siblings: [[Field; TREE_DEPTH]; MAX_CLAIMS] = [[0; TREE_DEPTH]; MAX_CLAIMS];

    claim_types[0] = TEST_HUMAN;
    issuer_ids[0] = issuer;
    expires_ats[0] = 0; // never expires

    let root = single_leaf_root(secret, TEST_HUMAN, issuer, 0);
    let nullifier = compute_nullifier(secret, TEST_APP, TEST_CTX);

    main(secret, issuer_ids, expires_ats, siblings, root, nullifier, TEST_APP, TEST_CTX, now, claim_types, 0);
}

// Expired claim (expires_at <= now) must reject.
#[test(should_fail)]
fn test_expired_rejected() {
    let secret: Field = 424242;
    let issuer: Field = 0x1D;
    let expires: u64 = 1000; // long past
    let now: u64 = 1900000000;

    let mut issuer_ids: [Field; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut expires_ats: [u64; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut claim_types: [Field; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut siblings: [[Field; TREE_DEPTH]; MAX_CLAIMS] = [[0; TREE_DEPTH]; MAX_CLAIMS];

    claim_types[0] = TEST_HUMAN;
    issuer_ids[0] = issuer;
    expires_ats[0] = expires;

    let root = single_leaf_root(secret, TEST_HUMAN, issuer, expires);
    let nullifier = compute_nullifier(secret, TEST_APP, TEST_CTX);

    main(secret, issuer_ids, expires_ats, siblings, root, nullifier, TEST_APP, TEST_CTX, now, claim_types, 0);
}

// Wrong root must reject.
#[test(should_fail)]
fn test_bad_root_rejected() {
    let secret: Field = 424242;
    let issuer: Field = 0x1D;
    let expires: u64 = 2000000000;
    let now: u64 = 1900000000;

    let mut issuer_ids: [Field; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut expires_ats: [u64; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut claim_types: [Field; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut siblings: [[Field; TREE_DEPTH]; MAX_CLAIMS] = [[0; TREE_DEPTH]; MAX_CLAIMS];

    claim_types[0] = TEST_HUMAN;
    issuer_ids[0] = issuer;
    expires_ats[0] = expires;

    let nullifier = compute_nullifier(secret, TEST_APP, TEST_CTX);
    main(secret, issuer_ids, expires_ats, siblings, 0xDEAD, nullifier, TEST_APP, TEST_CTX, now, claim_types, 0);
}

// Nullifier must bind to secret+app+context.
#[test(should_fail)]
fn test_wrong_nullifier_rejected() {
    let secret: Field = 424242;
    let issuer: Field = 0x1D;
    let expires: u64 = 2000000000;
    let now: u64 = 1900000000;

    let mut issuer_ids: [Field; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut expires_ats: [u64; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut claim_types: [Field; MAX_CLAIMS] = [0; MAX_CLAIMS];
    let mut siblings: [[Field; TREE_DEPTH]; MAX_CLAIMS] = [[0; TREE_DEPTH]; MAX_CLAIMS];

    claim_types[0] = TEST_HUMAN;
    issuer_ids[0] = issuer;
    expires_ats[0] = expires;

    let root = single_leaf_root(secret, TEST_HUMAN, issuer, expires);
    main(secret, issuer_ids, expires_ats, siblings, root, 0x1234, TEST_APP, TEST_CTX, now, claim_types, 0);
}
