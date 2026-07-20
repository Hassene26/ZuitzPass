// =============================================================================
// ZuitzPass -- Circuit C (one-shot): real-Luma email presentation
// =============================================================================
//
// docs/AGGREGATED_PROOFS_DESIGN.md 0.5. The NON-PERSISTENT path: prove, on-device,
// that you hold a real Luma registration-confirmation email for a specific event,
// and present it directly to OneShotEmailGate.sol -- no credential tree, no redeem,
// nothing stored. The gate verifies + consumes a per-app nullifier in one call.
//
// Unlike the persistent Circuit C (email_proof/, which matched a subject TOKEN and
// emitted C for insertion), this one models REAL Luma mail:
//   - From: <organizer>@calendar.luma-mail.com   (Luma-aligned sender, signed)
//   - Subject: "Registration confirmed for X"  OR  "Registration approved for X"
// Luma sends via Amazon SES, so the surviving passing DKIM signature is usually
// amazonses.com (its key covers From+Subject; SES only lets a verified domain owner
// send From that domain, so an SES-signed From @...luma-mail.com attests it is Luma).
//
// -----------------------------------------------------------------------------
// PUBLIC INPUTS (the Solidity pub[] array, in this exact order -- match
// OneShotEmailGate.N_PUB = 6). Each is a value the circuit ASSERTS it computed, so
// the gate reads them directly:
//   [0] key_hash_0 : Field -- pubkey.hash()[0]; gate checks DKIMKeyRegistry
//   [1] key_hash_1 : Field -- pubkey.hash()[1]
//   [2] event_id   : Field -- commitment to (From value, event name); gate pins it
//   [3] nullifier  : Field -- Poseidon3(secret, app_id, context_id); gate consumes once
//   [4] app_id     : Field -- appScope(caller, statementId); gate checks == its own
//   [5] context_id : Field -- epoch/instance; gate checks == its param
//
// Private witness (never leaves device): the signed header bytes + DKIM material,
// the From/Subject field locations, the extracted From-value + event-name buffers,
// and `secret`. `app_id`/`context_id` are public (chosen by the gate/caller); the
// nullifier binds them to the secret.
// =============================================================================

use poseidon::poseidon::bn254;
// Real Luma mail is signed by Amazon SES with a 1024-bit DKIM key (9 limbs), so this circuit uses
// KEY_LIMBS_1024. (The persistent email_proof/ used KEY_LIMBS_2048 for the self-signed 2048-bit
// samples -- different key size, different circuit.)
use zkemail::{dkim::RSAPubkey, headers::constrain_header_field, KEY_LIMBS_1024, Sequence};

global MAX_HEADER_LENGTH: u32 = 1408;
global MAX_HEADER_FIELD_LENGTH: u32 = 256; // bound for From/Subject fields (name + value)

// "from" / "subject" lengths (DKIM relaxed canonicalization lowercases header names).
global FROM_NAME_LENGTH: u32 = 4;
global SUBJECT_NAME_LENGTH: u32 = 7;

// Extraction buffers. Bump if a real From/event exceeds these (they are zero-padded).
global MAX_FROM_LENGTH: u32 = 128; // whole From value, e.g. 'Name <x@calendar.luma-mail.com>'
global MAX_EVENT_LENGTH: u32 = 96; // the event name X after the subject prefix

// The Luma sender domain that must appear in the From value.
global LUMA_DOMAIN: [u8; 23] = "@calendar.luma-mail.com".as_bytes();
// The two accepted subject prefixes (positive registration). Lengths differ by one.
global PREFIX_CONFIRMED: [u8; 27] = "Registration confirmed for ".as_bytes();
global PREFIX_APPROVED: [u8; 26] = "Registration approved for ".as_bytes();

// --- little hashing helpers --------------------------------------------------------------------
// Fold an array of field limbs into one Poseidon digest (Merkle-style, order-sensitive).
fn fold<let K: u32>(xs: [Field; K]) -> Field {
    let mut acc: Field = 0;
    for i in 0..K {
        acc = bn254::hash_2([acc, xs[i]]);
    }
    acc
}

// Pack a zero-padded byte buffer into 16-byte little-endian field limbs, then fold with the
// length. Injective for buffers whose padding past `len` is enforced zero (as the extractors do).
fn hash_bytes<let N: u32, let LIMBS: u32>(buf: [u8; N], len: u32) -> Field {
    let mut limbs: [Field; LIMBS] = [0; LIMBS];
    for l in 0..LIMBS {
        let mut acc: Field = 0;
        let mut mul: Field = 1;
        for j in 0..16 {
            let idx = l * 16 + j;
            let b = if idx < N { buf[idx] as Field } else { 0 };
            acc += b * mul;
            mul *= 256;
        }
        limbs[l] = acc;
    }
    bn254::hash_2([fold(limbs), len as Field])
}

// Assert `pattern` occurs in `header` starting at `at` (used for the fixed Luma domain / prefixes).
fn assert_substr<let N: u32>(header: BoundedVec<u8, MAX_HEADER_LENGTH>, at: u32, pattern: [u8; N]) {
    for i in 0..N {
        assert(header.get_unchecked(at + i) == pattern[i]);
    }
}

// Does `header` match `pattern` at `at`? (non-asserting, for prefix selection)
fn matches_at<let N: u32>(header: BoundedVec<u8, MAX_HEADER_LENGTH>, at: u32, pattern: [u8; N]) -> bool {
    let mut ok = true;
    for i in 0..N {
        ok = ok & (header.get_unchecked(at + i) == pattern[i]);
    }
    ok
}

// Copy header[start .. start+len] into a fixed buffer, asserting the copy is exact and the tail is
// zero-padded (so the buffer -> field hash is injective in (bytes, len)).
fn extract<let N: u32>(
    header: BoundedVec<u8, MAX_HEADER_LENGTH>,
    start: u32,
    len: u32,
    buf: [u8; N],
) {
    assert(len <= N);
    for i in 0..N {
        let active = i < len;
        let idx = if active { start + i } else { start }; // in-bounds read for inactive slots
        assert(!active | (header.get_unchecked(idx) == buf[i]));
        assert(active | (buf[i] == 0));
    }
}

fn main(
    // --- private witness ---
    header: BoundedVec<u8, MAX_HEADER_LENGTH>,
    pubkey: RSAPubkey<KEY_LIMBS_1024>,
    signature: [Field; KEY_LIMBS_1024],
    from_sequence: Sequence, // the From header field within `header`
    subject_sequence: Sequence, // the Subject header field within `header`
    from_value: [u8; MAX_FROM_LENGTH], // the From value bytes (zero-padded)
    from_value_len: u32,
    luma_at_index: u32, // index in `header` where "@calendar.luma-mail.com" starts
    event: [u8; MAX_EVENT_LENGTH], // the event name X (zero-padded)
    event_len: u32,
    secret: Field,
    // --- public INPUTS (the gate supplies + checks these) ---
    app_id: pub Field, // appScope(caller, statementId)
    context_id: pub Field, // epoch / instance
) -> pub [Field; 4] {
    // Computed public OUTPUTS (returned, never echoed): [key_hash_0, key_hash_1, event_id, nullifier].
    // 1. DKIM: the header carries a valid RSA-1024 (Amazon SES) signature under `pubkey`.
    let _ = pubkey.verify_dkim_signature(header, signature);
    let kh = pubkey.hash();

    // 2. From: a genuine signed `from:` field, whose value is a @calendar.luma-mail.com address.
    constrain_header_field::<MAX_HEADER_LENGTH, MAX_HEADER_FIELD_LENGTH, FROM_NAME_LENGTH>(
        header,
        from_sequence,
        "from".as_bytes(),
    );
    let from_value_start = from_sequence.index + FROM_NAME_LENGTH + 1;
    extract(header, from_value_start, from_value_len, from_value);
    // The Luma domain sits inside the From value (bounds + content).
    assert(luma_at_index >= from_value_start);
    assert(luma_at_index + (LUMA_DOMAIN.len() as u32) <= from_sequence.end_index());
    assert_substr(header, luma_at_index, LUMA_DOMAIN);

    // 3. Subject: a genuine signed `subject:` field starting with a positive-registration prefix.
    constrain_header_field::<MAX_HEADER_LENGTH, MAX_HEADER_FIELD_LENGTH, SUBJECT_NAME_LENGTH>(
        header,
        subject_sequence,
        "subject".as_bytes(),
    );
    let subject_value_start = subject_sequence.index + SUBJECT_NAME_LENGTH + 1;
    let is_confirmed = matches_at(header, subject_value_start, PREFIX_CONFIRMED);
    let is_approved = matches_at(header, subject_value_start, PREFIX_APPROVED);
    assert(is_confirmed | is_approved); // reject reminders / cancellations / anything else
    let prefix_len = if is_confirmed { PREFIX_CONFIRMED.len() as u32 } else { PREFIX_APPROVED.len() as u32 };
    let event_start = subject_value_start + prefix_len;
    // The event name is exactly the rest of the subject value.
    assert(event_start + event_len == subject_sequence.end_index());
    extract(header, event_start, event_len, event);

    // 4. event_id commits to (From value, event name) -> "attended event X by organizer Y".
    let from_hash = hash_bytes::<MAX_FROM_LENGTH, 8>(from_value, from_value_len);
    let event_hash = hash_bytes::<MAX_EVENT_LENGTH, 6>(event, event_len);
    let event_id = bn254::hash_2([from_hash, event_hash]);

    // 5. nullifier binds the secret to (app_id, context_id): app-scoped + single-use, unlinkable.
    let nullifier = bn254::hash_3([secret, app_id, context_id]);

    // Public output order MUST match OneShotEmailGate: the full pub[] the gate reads is
    // [app_id, context_id]  (public inputs, declaration order)  ++  [kh0, kh1, event_id, nullifier].
    [kh[0], kh[1], event_id, nullifier]
}

// =============================================================================
// Tests -- the From/subject extraction + event_id/nullifier logic over synthetic
// (non-DKIM) headers. The DKIM path is exercised by `nargo execute` over a real
// generated fixture, because an RSA signature can't be fabricated in a unit test.
// =============================================================================

// "from:Org <bsaepfl@calendar.luma-mail.com>\r\nsubject:Registration confirmed for Trezor\r\n"
// Build a header where from starts at 0 and subject follows.
fn demo_header() -> BoundedVec<u8, MAX_HEADER_LENGTH> {
    BoundedVec::from_array(
        "from:Org <bsaepfl@calendar.luma-mail.com>\r\nsubject:Registration confirmed for Trezor\r\n"
            .as_bytes(),
    )
}

fn buf_from<let N: u32>(s: [u8; N]) -> ([u8; MAX_FROM_LENGTH], u32) {
    let mut b: [u8; MAX_FROM_LENGTH] = [0; MAX_FROM_LENGTH];
    for i in 0..N {
        b[i] = s[i];
    }
    (b, N)
}

fn buf_event<let N: u32>(s: [u8; N]) -> ([u8; MAX_EVENT_LENGTH], u32) {
    let mut b: [u8; MAX_EVENT_LENGTH] = [0; MAX_EVENT_LENGTH];
    for i in 0..N {
        b[i] = s[i];
    }
    (b, N)
}

#[test]
fn test_extract_from_value_and_domain() {
    let header = demo_header();
    // From field: "from:Org <bsaepfl@calendar.luma-mail.com>" ; value = "Org <bsaepfl@...com>"
    let (fbuf, flen) = buf_from("Org <bsaepfl@calendar.luma-mail.com>".as_bytes());
    let from_value_start = 0 + FROM_NAME_LENGTH + 1; // after "from:"
    extract(header, from_value_start, flen, fbuf);
    // "@calendar.luma-mail.com" starts right after "from:Org <bsaepfl" = index 17.
    assert_substr(header, 17, LUMA_DOMAIN);
}

#[test]
fn test_subject_prefix_and_event() {
    let header = demo_header();
    // subject field begins after the From field + CRLF.
    let subject_index = 43; // "from:...com>\r\n" is 41 + 2 = 43
    // "subject:Registration confirmed for Trezor" = 8 + 27 + 6 = 41 bytes.
    let subject_seq = Sequence { index: subject_index, length: 41 };
    let vs = subject_index + SUBJECT_NAME_LENGTH + 1;
    assert(matches_at(header, vs, PREFIX_CONFIRMED));
    let event_start = vs + PREFIX_CONFIRMED.len() as u32;
    let (ebuf, elen) = buf_event("Trezor".as_bytes());
    assert(event_start + elen == subject_seq.end_index());
    extract(header, event_start, elen, ebuf);
}

#[test]
fn test_event_id_binds_from_and_event() {
    let (f1, l1) = buf_from("Org A <a@calendar.luma-mail.com>".as_bytes());
    let (f2, l2) = buf_from("Org B <b@calendar.luma-mail.com>".as_bytes());
    let (e, el) = buf_event("Same Event".as_bytes());
    let id1 = bn254::hash_2([hash_bytes::<MAX_FROM_LENGTH, 8>(f1, l1), hash_bytes::<MAX_EVENT_LENGTH, 6>(e, el)]);
    let id2 = bn254::hash_2([hash_bytes::<MAX_FROM_LENGTH, 8>(f2, l2), hash_bytes::<MAX_EVENT_LENGTH, 6>(e, el)]);
    // Different organizer -> different event_id even for the same event name.
    assert(id1 != id2);
}

#[test(should_fail)]
fn test_rejects_non_registration_subject() {
    // A "cancelled" subject must not match either accepted prefix.
    let header: BoundedVec<u8, MAX_HEADER_LENGTH> =
        BoundedVec::from_array("subject:Registration cancelled for Trezor\r\n".as_bytes());
    let vs = 0 + SUBJECT_NAME_LENGTH + 1;
    let is_confirmed = matches_at(header, vs, PREFIX_CONFIRMED);
    let is_approved = matches_at(header, vs, PREFIX_APPROVED);
    assert(is_confirmed | is_approved);
}

#[test]
fn test_nullifier_binds_scope() {
    let secret: Field = 424242;
    let n1 = bn254::hash_3([secret, 111, 1]);
    let n2 = bn254::hash_3([secret, 222, 1]); // different app_id
    assert(n1 != n2);
}
