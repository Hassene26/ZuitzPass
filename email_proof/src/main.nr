// =============================================================================
// ZuitzPass -- Circuit C: Email evidence (signed-document class, zk-email)
// =============================================================================
//
// docs/PRIVATE_PROVABILITY_FRAMEWORK.md Part B. Proves, entirely on the user's
// device, that a DKIM-signed email (e.g. a Luma ticket confirmation) exists whose
// SIGNED subject header contains a specific event token -- and binds the proof to
// the prover's credential commitment C = Poseidon2(secret, r), so the credential
// can later be redeemed onto their master identity via the UNCHANGED Part-B flow
// (issuance_proof / RedeemIssuer / ClaimsSMTRegistry).
//
// DKIM verification comes from the audited zkemail.nr library (RSA-2048/SHA-256,
// relaxed canonicalization). Header-only: the body is represented solely by its
// signed bh= hash, which we never open -- no body bytes enter the circuit.
//
// Proves, in zero knowledge, that the prover:
//   1. Holds an email header carrying a valid DKIM signature under `pubkey`
//      (whose Poseidon key-hash is exposed -- the contract maps key -> domain).
//   2. That header contains a `subject:` field (CRLF-delimited, name-checked by
//      zkemail.nr) whose VALUE contains `token` at `token_index` -- the event
//      discriminator (framework invariant I4: signed bytes only).
//   3. Derived email_nullifier = pedersen(signature) -- deterministic per email,
//      one credential per email ever (invariant I5).
//   4. Knows (secret, r) opening C = Poseidon2(secret, r) -- the binding
//      (invariant I3 rung 3): a stolen proof cannot be re-bound, and the email
//      prover and identity owner are the same proving session.
//
// -----------------------------------------------------------------------------
// PUBLIC OUTPUTS (return values -- contract with EmailEvidenceVerifier.sol),
// in order:
//   [0] dkim_key_hash[0] : Field -- Poseidon hash of the RSA pubkey limbs (half 1)
//   [1] dkim_key_hash[1] : Field -- (half 2); contract checks both against DKIMKeyRegistry
//   [2] event_id         : Field -- Poseidon3(token_lo, token_hi, token_length);
//                                  contract pins it per registered source (WHICH event)
//   [3] email_nullifier  : Field -- pedersen(signature limbs); contract consumes once
//   [4] cred_commitment  : Field -- C = Poseidon2(secret, r); contract inserts into
//                                  the per-event VerifiedHumansTree (Part A)
//
// All circuit outputs are COMPUTED in-circuit (nothing echoed), so the input
// generator never re-implements any hash. Private witness never leaves the device:
// header bytes, pubkey limbs, signature limbs, subject location, token, secret, r.
// =============================================================================

use poseidon::poseidon::bn254;
use zkemail::{dkim::RSAPubkey, headers::constrain_header_field, KEY_LIMBS_2048, Sequence};

// Multiple of 64 (SHA block size). Bump if a real source's signed header block is longer.
global MAX_HEADER_LENGTH: u32 = 1408;
// Max length of the subject header FIELD (name + value), per zkemail.nr's bounds check.
global MAX_SUBJECT_LENGTH: u32 = 192;
// Fixed token buffer; actual token_length may be shorter (rest must be zero).
global MAX_TOKEN_LENGTH: u32 = 32;
// "subject" (lowercase -- DKIM relaxed canonicalization lowercases header names).
global SUBJECT_NAME_LENGTH: u32 = 7;

// C = Poseidon2(secret, r) -- must equal issuance_proof's compute_commitment.
fn compute_commitment(secret: Field, r: Field) -> Field {
    bn254::hash_2([secret, r])
}

// Event discriminator commitment: pack the 32-byte token buffer into two 16-byte
// fields (little-endian base-256) and hash with the length. Zero-padding beyond
// token_length is ENFORCED in check_subject_token, so (token, length) -> event_id
// is injective for tokens up to 32 bytes.
fn compute_event_id(token: [u8; MAX_TOKEN_LENGTH], token_length: u32) -> Field {
    let mut lo: Field = 0;
    let mut hi: Field = 0;
    let mut mul: Field = 1;
    for i in 0..16 {
        lo += (token[i] as Field) * mul;
        hi += (token[i + 16] as Field) * mul;
        mul *= 256;
    }
    bn254::hash_3([lo, hi, token_length as Field])
}

// The content-specificity gadget (invariant I4): `subject_sequence` is a genuine
// CRLF-delimited `subject:` header field (zkemail.nr checks the name bytes, the
// colon, the delimiters, and no-CRLF-inside), and the token bytes sit wholly
// inside that field's VALUE region of the signed header.
fn check_subject_token(
    header: BoundedVec<u8, MAX_HEADER_LENGTH>,
    subject_sequence: Sequence,
    token: [u8; MAX_TOKEN_LENGTH],
    token_length: u32,
    token_index: u32,
) {
    constrain_header_field::<MAX_HEADER_LENGTH, MAX_SUBJECT_LENGTH, SUBJECT_NAME_LENGTH>(
        header,
        subject_sequence,
        "subject".as_bytes(),
    );

    assert(token_length >= 1);
    assert(token_length <= MAX_TOKEN_LENGTH);

    // Value region starts after "subject" + ':'.
    let value_start = subject_sequence.index + SUBJECT_NAME_LENGTH + 1;
    assert(token_index >= value_start);
    assert(token_index + token_length <= subject_sequence.end_index());

    for i in 0..MAX_TOKEN_LENGTH {
        let active = i < token_length;
        // Inactive slots read a known-in-bounds index so no out-of-range access occurs.
        let idx = if active { token_index + i } else { value_start };
        let byte = header.get_unchecked(idx);
        // Active: header byte must equal the token byte. Inactive: token padding must be 0.
        assert(!active | (byte == token[i]));
        assert(active | (token[i] == 0));
    }
}

fn main(
    // --- private witness (never leaves the device) ---
    header: BoundedVec<u8, MAX_HEADER_LENGTH>,
    pubkey: RSAPubkey<KEY_LIMBS_2048>,
    signature: [Field; KEY_LIMBS_2048],
    subject_sequence: Sequence,
    token: [u8; MAX_TOKEN_LENGTH],
    token_length: u32,
    token_index: u32,
    secret: Field,
    r: Field,
) -> pub [Field; 5] {
    // 1. DKIM: the header carries a valid RSA-2048 signature under `pubkey`.
    let _header_hash = pubkey.verify_dkim_signature(header, signature);

    // 2. Which key signed -- the contract decides whether that key belongs to the
    //    source's domain (DKIMKeyRegistry), so key rotation is config, not circuits.
    let key_hash = pubkey.hash();

    // 3. Content specificity: the event token is in the signed subject value.
    check_subject_token(header, subject_sequence, token, token_length, token_index);
    let event_id = compute_event_id(token, token_length);

    // 4. One credential per email, ever: deterministic nullifier over the signature
    //    (unique per message; reveals nothing about the content).
    let email_nullifier = std::hash::pedersen_hash(signature);

    // 5. The binding: C opens to (secret, r) in THIS proving session.
    let cred_commitment = compute_commitment(secret, r);

    [key_hash[0], key_hash[1], event_id, email_nullifier, cred_commitment]
}

// =============================================================================
// Tests -- the subject/token/event-id logic with synthetic (non-DKIM) headers.
// The DKIM path itself is exercised by `nargo execute` over a real generated
// fixture (demo-app/backend/make-email-proof-inputs.mjs -> Prover.toml), because
// an RSA signature cannot be fabricated in a unit test.
// =============================================================================

// "subject:your ticket evt_cannes2026 ok\r\n" -- value starts at 8, token at 20, len 14.
fn test_header() -> BoundedVec<u8, MAX_HEADER_LENGTH> {
    BoundedVec::from_array("subject:your ticket evt_cannes2026 ok\r\n".as_bytes())
}

fn test_token() -> ([u8; MAX_TOKEN_LENGTH], u32, u32) {
    let bytes = "evt_cannes2026".as_bytes();
    let mut token: [u8; MAX_TOKEN_LENGTH] = [0; MAX_TOKEN_LENGTH];
    for i in 0..14 {
        token[i] = bytes[i];
    }
    (token, 14, 20)
}

#[test]
fn test_subject_token_happy_path() {
    let (token, token_length, token_index) = test_token();
    // Field covers the line minus the trailing CRLF.
    let seq = Sequence { index: 0, length: 37 };
    check_subject_token(test_header(), seq, token, token_length, token_index);
}

#[test]
fn test_event_id_binds_length() {
    let (token, token_length, _) = test_token();
    // Same buffer, different claimed length => different event id (no prefix collisions).
    assert(compute_event_id(token, token_length) != compute_event_id(token, token_length - 1));
}

#[test(should_fail)]
fn test_token_mismatch_rejected() {
    let (mut token, token_length, token_index) = test_token();
    token[0] = "x".as_bytes()[0]; // not the header's byte
    let seq = Sequence { index: 0, length: 37 };
    check_subject_token(test_header(), seq, token, token_length, token_index);
}

#[test(should_fail)]
fn test_token_outside_subject_rejected() {
    let (token, token_length, _) = test_token();
    let seq = Sequence { index: 0, length: 37 };
    // Points past the subject field's end.
    check_subject_token(test_header(), seq, token, token_length, 30);
}

#[test(should_fail)]
fn test_dirty_padding_rejected() {
    let (mut token, token_length, token_index) = test_token();
    token[20] = 1; // padding beyond token_length must be zero (event_id injectivity)
    let seq = Sequence { index: 0, length: 37 };
    check_subject_token(test_header(), seq, token, token_length, token_index);
}

#[test(should_fail)]
fn test_wrong_header_name_rejected() {
    let (token, token_length, _) = test_token();
    let header: BoundedVec<u8, MAX_HEADER_LENGTH> =
        BoundedVec::from_array("to:alice ticket evt_cannes2026 pad\r\n".as_bytes());
    let seq = Sequence { index: 0, length: 34 };
    check_subject_token(header, seq, token, token_length, 16);
}
