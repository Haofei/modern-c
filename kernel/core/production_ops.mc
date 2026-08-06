// kernel/core/production_ops — production control-plane primitives.
//
// These are host-testable, data-oriented pieces behind the production checklist: bundle
// admission, rollback decision state, watchdog/reboot reason reporting, and policy actuation.
// Hardware-specific reset and crypto verification remain behind callers, but the kernel-visible
// state transitions are explicit and gated here.

import "std/math.mc";

pub enum BundleKind {
    Kernel,
    Policy,
    Agent,
}

pub enum BundleError {
    BadMagic,
    BadKind,
    BadAbi,
    BadVersion,
    BadSignature,
    WrongKey,
    BadImageHash,
}

const BUNDLE_MAGIC: u32 = 0x4d43424e; // "MCBN"
const BUNDLE_FNV_OFFSET: u32 = 0x811c9dc5;
const BUNDLE_FNV_PRIME: u32 = 0x0100_0193;
pub const BUNDLE_DIGEST_LEN: usize = 32;

pub struct BundleDigest {
    bytes: [32]u8,
}

pub struct BundleHeader {
    magic: u32,
    kind: BundleKind,
    version: u64,
    abi_version: u32,
    policy_version: u64,
    key_id: u32,
    image_hash: u64,
    image_digest: BundleDigest,
    signature_len: usize,
}

// Opaque admission token for a bundle whose metadata, signature-verification
// result, and exact image bytes have been checked together. Metadata-only
// validation deliberately cannot create a `VerifiedBundle`: loader and rollback
// consumers must receive a token whose byte range is bound to the same image
// they will consume. The digest is SHA-256 over the admitted image bytes. Real
// secure boot still requires this digest to be covered by signature verification
// and anti-rollback storage policy; the token shape no longer depends on the
// legacy FNV u64 metadata bridge.
pub linear opaque struct VerifiedBundle {
    kind: BundleKind,
    version: u64,
    abi_version: u32,
    policy_version: u64,
    key_id: u32,
    image_hash: u64,
    image_digest: BundleDigest,
    image_base: usize,
    image_len: usize,
    exact_bytes: bool,
}

fn bundle_digest_from_legacy_hash(image_hash: u64) -> BundleDigest {
    var d: BundleDigest = .{ .bytes = .{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    } };
    d.bytes[24] = ((image_hash >> 56) & 0xFF) as u8;
    d.bytes[25] = ((image_hash >> 48) & 0xFF) as u8;
    d.bytes[26] = ((image_hash >> 40) & 0xFF) as u8;
    d.bytes[27] = ((image_hash >> 32) & 0xFF) as u8;
    d.bytes[28] = ((image_hash >> 24) & 0xFF) as u8;
    d.bytes[29] = ((image_hash >> 16) & 0xFF) as u8;
    d.bytes[30] = ((image_hash >> 8) & 0xFF) as u8;
    d.bytes[31] = (image_hash & 0xFF) as u8;
    return d;
}

pub fn bundle_header_init(kind: BundleKind, version: u64, abi_version: u32, policy_version: u64, key_id: u32, image_hash: u64, signature_len: usize) -> BundleHeader {
    return .{
        .magic = BUNDLE_MAGIC,
        .kind = kind,
        .version = version,
        .abi_version = abi_version,
        .policy_version = policy_version,
        .key_id = key_id,
        .image_hash = image_hash,
        .image_digest = bundle_digest_from_legacy_hash(image_hash),
        .signature_len = signature_len,
    };
}

pub fn bundle_header_init_digest(kind: BundleKind, version: u64, abi_version: u32, policy_version: u64, key_id: u32, image_hash: u64, image_digest: BundleDigest, signature_len: usize) -> BundleHeader {
    return .{
        .magic = BUNDLE_MAGIC,
        .kind = kind,
        .version = version,
        .abi_version = abi_version,
        .policy_version = policy_version,
        .key_id = key_id,
        .image_hash = image_hash,
        .image_digest = image_digest,
        .signature_len = signature_len,
    };
}

fn bundle_kind_matches(actual: BundleKind, expected: BundleKind) -> bool {
    switch expected {
        .Kernel => {
            switch actual {
                .Kernel => { return true; }
                _ => { return false; }
            }
        }
        .Policy => {
            switch actual {
                .Policy => { return true; }
                _ => { return false; }
            }
        }
        .Agent => {
            switch actual {
                .Agent => { return true; }
                _ => { return false; }
            }
        }
    }
}

// Validate canonical bundle metadata only. `signature_len != 0` means the header
// has a signature-shaped field, not that the signature has been cryptographically
// accepted. Only `bundle_verify_and_admit_image` can create a `VerifiedBundle`,
// and it requires the caller to pass the result of the crypto verification seam.
// Callers cannot inject a `.Valid` enum into this metadata state machine.
pub fn bundle_validate_metadata(h: *BundleHeader, expected_kind: BundleKind, expected_abi: u32, min_version: u64, max_version: u64, trusted_key_id: u32) -> Result<bool, BundleError> {
    if h.magic != BUNDLE_MAGIC {
        return err(.BadMagic);
    }
    if !bundle_kind_matches(h.kind, expected_kind) {
        return err(.BadKind);
    }
    if h.abi_version != expected_abi {
        return err(.BadAbi);
    }
    if h.version < min_version {
        return err(.BadVersion);
    }
    if h.version > max_version {
        return err(.BadVersion);
    }
    if h.key_id != trusted_key_id {
        return err(.WrongKey);
    }
    if h.signature_len == 0 {
        return err(.BadSignature);
    }
    return ok(true);
}

pub fn bundle_image_hash_matches(h: *BundleHeader, expected_hash: u64) -> bool {
    return h.image_hash == expected_hash;
}

fn bundle_wrap_mul_u32(a: u32, b: u32) -> u32 {
    return (((a as u64) * (b as u64)) & 0x0000_0000_FFFF_FFFF) as u32;
}

fn bundle_fnv_step(h: u32, byte: u8) -> u32 {
    let mixed: u32 = h ^ (byte as u32);
    return bundle_wrap_mul_u32(mixed, BUNDLE_FNV_PRIME);
}

fn bundle_image_range_valid(base: usize, len: usize) -> bool {
    if len == 0 {
        return true;
    }
    let usize_max: usize = 0xFFFF_FFFF_FFFF_FFFF as usize;
    return base <= usize_max - len;
}

pub fn bundle_hash_bytes(base: usize, len: usize) -> u64 {
    var h: u32 = BUNDLE_FNV_OFFSET;
    var i: usize = 0;
    while i < len {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        h = bundle_fnv_step(h, b);
        i = i + 1;
    }
    return h as u64;
}

fn bundle_digest_zero() -> BundleDigest {
    return .{ .bytes = .{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    } };
}

fn bundle_sha256_padding_valid(len: usize) -> bool {
    let usize_max: usize = 0xFFFF_FFFF_FFFF_FFFF as usize;
    if len > usize_max - 72 {
        return false;
    }
    if len > (usize_max / 8) {
        return false;
    }
    return true;
}

fn bundle_rotr32(x: u32, n: u32) -> u32 {
    return (x >> n) | wrapping_shl_u32(x, 32 - n);
}

fn bundle_sha256_ch(x: u32, y: u32, z: u32) -> u32 {
    return (x & y) ^ ((~x) & z);
}

fn bundle_sha256_maj(x: u32, y: u32, z: u32) -> u32 {
    return (x & y) ^ (x & z) ^ (y & z);
}

fn bundle_sha256_big0(x: u32) -> u32 {
    return bundle_rotr32(x, 2) ^ bundle_rotr32(x, 13) ^ bundle_rotr32(x, 22);
}

fn bundle_sha256_big1(x: u32) -> u32 {
    return bundle_rotr32(x, 6) ^ bundle_rotr32(x, 11) ^ bundle_rotr32(x, 25);
}

fn bundle_sha256_small0(x: u32) -> u32 {
    return bundle_rotr32(x, 7) ^ bundle_rotr32(x, 18) ^ (x >> 3);
}

fn bundle_sha256_small1(x: u32) -> u32 {
    return bundle_rotr32(x, 17) ^ bundle_rotr32(x, 19) ^ (x >> 10);
}

fn bundle_sha256_add4(a: u32, b: u32, c: u32, d: u32) -> u32 {
    return wrapping_add_u32(wrapping_add_u32(wrapping_add_u32(a, b), c), d);
}

fn bundle_sha256_add5(a: u32, b: u32, c: u32, d: u32, e: u32) -> u32 {
    return wrapping_add_u32(bundle_sha256_add4(a, b, c, d), e);
}

fn bundle_sha256_k(i: usize) -> u32 {
    switch i {
        0 => { return 0x428a2f98; }
        1 => { return 0x71374491; }
        2 => { return 0xb5c0fbcf; }
        3 => { return 0xe9b5dba5; }
        4 => { return 0x3956c25b; }
        5 => { return 0x59f111f1; }
        6 => { return 0x923f82a4; }
        7 => { return 0xab1c5ed5; }
        8 => { return 0xd807aa98; }
        9 => { return 0x12835b01; }
        10 => { return 0x243185be; }
        11 => { return 0x550c7dc3; }
        12 => { return 0x72be5d74; }
        13 => { return 0x80deb1fe; }
        14 => { return 0x9bdc06a7; }
        15 => { return 0xc19bf174; }
        16 => { return 0xe49b69c1; }
        17 => { return 0xefbe4786; }
        18 => { return 0x0fc19dc6; }
        19 => { return 0x240ca1cc; }
        20 => { return 0x2de92c6f; }
        21 => { return 0x4a7484aa; }
        22 => { return 0x5cb0a9dc; }
        23 => { return 0x76f988da; }
        24 => { return 0x983e5152; }
        25 => { return 0xa831c66d; }
        26 => { return 0xb00327c8; }
        27 => { return 0xbf597fc7; }
        28 => { return 0xc6e00bf3; }
        29 => { return 0xd5a79147; }
        30 => { return 0x06ca6351; }
        31 => { return 0x14292967; }
        32 => { return 0x27b70a85; }
        33 => { return 0x2e1b2138; }
        34 => { return 0x4d2c6dfc; }
        35 => { return 0x53380d13; }
        36 => { return 0x650a7354; }
        37 => { return 0x766a0abb; }
        38 => { return 0x81c2c92e; }
        39 => { return 0x92722c85; }
        40 => { return 0xa2bfe8a1; }
        41 => { return 0xa81a664b; }
        42 => { return 0xc24b8b70; }
        43 => { return 0xc76c51a3; }
        44 => { return 0xd192e819; }
        45 => { return 0xd6990624; }
        46 => { return 0xf40e3585; }
        47 => { return 0x106aa070; }
        48 => { return 0x19a4c116; }
        49 => { return 0x1e376c08; }
        50 => { return 0x2748774c; }
        51 => { return 0x34b0bcb5; }
        52 => { return 0x391c0cb3; }
        53 => { return 0x4ed8aa4a; }
        54 => { return 0x5b9cca4f; }
        55 => { return 0x682e6ff3; }
        56 => { return 0x748f82ee; }
        57 => { return 0x78a5636f; }
        58 => { return 0x84c87814; }
        59 => { return 0x8cc70208; }
        60 => { return 0x90befffa; }
        61 => { return 0xa4506ceb; }
        62 => { return 0xbef9a3f7; }
        63 => { return 0xc67178f2; }
        _ => { return 0; }
    }
}

fn bundle_sha256_block_byte(base: usize, len: usize, padded_len: usize, block_start: usize, byte_index: usize) -> u8 {
    let absolute: usize = block_start + byte_index;
    if absolute < len {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + absolute)); }
        return b;
    }
    if absolute == len {
        return 0x80;
    }
    if absolute >= padded_len - 8 {
        let bit_len: u64 = (len as u64) * 8;
        let tail: usize = absolute - (padded_len - 8);
        let shift: u64 = ((7 - tail) * 8) as u64;
        return ((bit_len >> shift) & 0xFF) as u8;
    }
    return 0;
}

fn bundle_sha256_store_word(d: *mut BundleDigest, offset: usize, word: u32) -> void {
    d.bytes[offset + 0] = ((word >> 24) & 0xFF) as u8;
    d.bytes[offset + 1] = ((word >> 16) & 0xFF) as u8;
    d.bytes[offset + 2] = ((word >> 8) & 0xFF) as u8;
    d.bytes[offset + 3] = (word & 0xFF) as u8;
}

pub fn bundle_digest_equal(a: *BundleDigest, b: *BundleDigest) -> bool {
    var i: usize = 0;
    var diff: u8 = 0;
    while i < BUNDLE_DIGEST_LEN {
        diff = diff | (a.bytes[i] ^ b.bytes[i]);
        i = i + 1;
    }
    return diff == 0;
}

pub fn bundle_digest_bytes(base: usize, len: usize) -> BundleDigest {
    if !bundle_sha256_padding_valid(len) {
        return bundle_digest_zero();
    }

    var h0: u32 = 0x6a09e667;
    var h1: u32 = 0xbb67ae85;
    var h2: u32 = 0x3c6ef372;
    var h3: u32 = 0xa54ff53a;
    var h4: u32 = 0x510e527f;
    var h5: u32 = 0x9b05688c;
    var h6: u32 = 0x1f83d9ab;
    var h7: u32 = 0x5be0cd19;

    let padded_len: usize = ((len + 1 + 8 + 63) / 64) * 64;
    var block_start: usize = 0;
    while block_start < padded_len {
        var w: [64]u32 = .{
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
        };
        var t: usize = 0;
        while t < 16 {
            let b0: u32 = bundle_sha256_block_byte(base, len, padded_len, block_start, t * 4 + 0) as u32;
            let b1: u32 = bundle_sha256_block_byte(base, len, padded_len, block_start, t * 4 + 1) as u32;
            let b2: u32 = bundle_sha256_block_byte(base, len, padded_len, block_start, t * 4 + 2) as u32;
            let b3: u32 = bundle_sha256_block_byte(base, len, padded_len, block_start, t * 4 + 3) as u32;
            w[t] = wrapping_shl_u32(b0, 24) | wrapping_shl_u32(b1, 16) | wrapping_shl_u32(b2, 8) | b3;
            t = t + 1;
        }
        while t < 64 {
            w[t] = bundle_sha256_add4(bundle_sha256_small1(w[t - 2]), w[t - 7], bundle_sha256_small0(w[t - 15]), w[t - 16]);
            t = t + 1;
        }

        var a: u32 = h0;
        var b: u32 = h1;
        var c: u32 = h2;
        var d: u32 = h3;
        var e: u32 = h4;
        var f: u32 = h5;
        var g: u32 = h6;
        var h: u32 = h7;

        t = 0;
        while t < 64 {
            let t1: u32 = bundle_sha256_add5(h, bundle_sha256_big1(e), bundle_sha256_ch(e, f, g), bundle_sha256_k(t), w[t]);
            let t2: u32 = wrapping_add_u32(bundle_sha256_big0(a), bundle_sha256_maj(a, b, c));
            h = g;
            g = f;
            f = e;
            e = wrapping_add_u32(d, t1);
            d = c;
            c = b;
            b = a;
            a = wrapping_add_u32(t1, t2);
            t = t + 1;
        }

        h0 = wrapping_add_u32(h0, a);
        h1 = wrapping_add_u32(h1, b);
        h2 = wrapping_add_u32(h2, c);
        h3 = wrapping_add_u32(h3, d);
        h4 = wrapping_add_u32(h4, e);
        h5 = wrapping_add_u32(h5, f);
        h6 = wrapping_add_u32(h6, g);
        h7 = wrapping_add_u32(h7, h);

        block_start = block_start + 64;
    }

    var out: BundleDigest = bundle_digest_zero();
    bundle_sha256_store_word(&out, 0, h0);
    bundle_sha256_store_word(&out, 4, h1);
    bundle_sha256_store_word(&out, 8, h2);
    bundle_sha256_store_word(&out, 12, h3);
    bundle_sha256_store_word(&out, 16, h4);
    bundle_sha256_store_word(&out, 20, h5);
    bundle_sha256_store_word(&out, 24, h6);
    bundle_sha256_store_word(&out, 28, h7);
    return out;
}

pub fn bundle_header_init_for_image(kind: BundleKind, version: u64, abi_version: u32, policy_version: u64, key_id: u32, image_base: usize, image_len: usize, signature_len: usize) -> BundleHeader {
    return bundle_header_init_digest(kind, version, abi_version, policy_version, key_id, bundle_hash_bytes(image_base, image_len), bundle_digest_bytes(image_base, image_len), signature_len);
}

impl VerifiedBundle {
    fn admit_image(h: *BundleHeader, expected_kind: BundleKind, expected_abi: u32, min_version: u64, max_version: u64, trusted_key_id: u32, signature_verified: bool, image_base: usize, image_len: usize) -> Result<VerifiedBundle, BundleError> {
        switch bundle_validate_metadata(h, expected_kind, expected_abi, min_version, max_version, trusted_key_id) {
            ok(v) => {}
            err(e) => { return err(e); }
        }
        if !signature_verified {
            return err(.BadSignature);
        }
        if !bundle_image_range_valid(image_base, image_len) {
            return err(.BadImageHash);
        }
        if !bundle_sha256_padding_valid(image_len) {
            return err(.BadImageHash);
        }
        var actual_digest: BundleDigest = bundle_digest_bytes(image_base, image_len);
        if !bundle_digest_equal(&h.image_digest, &actual_digest) {
            return err(.BadImageHash);
        }
        return ok(.{
            .kind = h.kind,
            .version = h.version,
            .abi_version = h.abi_version,
            .policy_version = h.policy_version,
            .key_id = h.key_id,
            .image_hash = h.image_hash,
            .image_digest = h.image_digest,
            .image_base = image_base,
            .image_len = image_len,
            .exact_bytes = true,
        });
    }

    fn kind(v: *VerifiedBundle) -> BundleKind {
        return v.kind;
    }
    fn version(v: *VerifiedBundle) -> u64 {
        return v.version;
    }
    fn image_hash(v: *VerifiedBundle) -> u64 {
        return v.image_hash;
    }
    fn image_digest(v: *VerifiedBundle) -> BundleDigest {
        return v.image_digest;
    }
    fn key_id(v: *VerifiedBundle) -> u32 {
        return v.key_id;
    }
    fn image_base(v: *VerifiedBundle) -> usize {
        return v.image_base;
    }
    fn image_len(v: *VerifiedBundle) -> usize {
        return v.image_len;
    }
    fn has_exact_bytes(v: *VerifiedBundle) -> bool {
        return v.exact_bytes;
    }
}

pub fn bundle_validate_metadata_hash(h: *BundleHeader, expected_kind: BundleKind, expected_abi: u32, min_version: u64, max_version: u64, trusted_key_id: u32, expected_image_hash: u64) -> Result<bool, BundleError> {
    switch bundle_validate_metadata(h, expected_kind, expected_abi, min_version, max_version, trusted_key_id) {
        ok(v) => {}
        err(e) => { return err(e); }
    }
    if h.image_hash != expected_image_hash {
        return err(.BadImageHash);
    }
    return ok(true);
}

pub fn bundle_verify_and_admit_image(h: *BundleHeader, expected_kind: BundleKind, expected_abi: u32, min_version: u64, max_version: u64, trusted_key_id: u32, signature_verified: bool, image_base: usize, image_len: usize) -> Result<VerifiedBundle, BundleError> {
    return VerifiedBundle.admit_image(h, expected_kind, expected_abi, min_version, max_version, trusted_key_id, signature_verified, image_base, image_len);
}

pub fn verified_bundle_kind(v: *VerifiedBundle) -> BundleKind {
    return VerifiedBundle.kind(v);
}

pub fn verified_bundle_version(v: *VerifiedBundle) -> u64 {
    return VerifiedBundle.version(v);
}

pub fn verified_bundle_image_hash(v: *VerifiedBundle) -> u64 {
    return VerifiedBundle.image_hash(v);
}

pub fn verified_bundle_image_digest(v: *VerifiedBundle) -> BundleDigest {
    return VerifiedBundle.image_digest(v);
}

pub fn verified_bundle_key_id(v: *VerifiedBundle) -> u32 {
    return VerifiedBundle.key_id(v);
}

pub fn verified_bundle_has_exact_bytes(v: *VerifiedBundle) -> bool {
    return VerifiedBundle.has_exact_bytes(v);
}

pub fn verified_bundle_image_base(v: *VerifiedBundle) -> usize {
    return VerifiedBundle.image_base(v);
}

pub fn verified_bundle_image_len(v: *VerifiedBundle) -> usize {
    return VerifiedBundle.image_len(v);
}

pub fn verified_bundle_matches_image(v: *VerifiedBundle, image_base: usize, image_len: usize) -> bool {
    if !VerifiedBundle.has_exact_bytes(v) {
        return false;
    }
    if image_base != VerifiedBundle.image_base(v) {
        return false;
    }
    if image_len != VerifiedBundle.image_len(v) {
        return false;
    }
    if !bundle_image_range_valid(image_base, image_len) {
        return false;
    }
    if !bundle_sha256_padding_valid(image_len) {
        return false;
    }
    var actual_digest: BundleDigest = bundle_digest_bytes(image_base, image_len);
    var token_digest: BundleDigest = VerifiedBundle.image_digest(v);
    return bundle_digest_equal(&actual_digest, &token_digest);
}

pub enum SlotState {
    Empty,
    Installed,
    Booting,
    Good,
    Failed,
}

pub struct UpdateSlot {
    version: u64,
    state: SlotState,
    failed_boots: u32,
}

pub struct RollbackState {
    active: usize,
    previous: usize,
    slots: [2]UpdateSlot,
}

pub fn rollback_state_valid(r: *RollbackState) -> bool {
    if r.active >= 2 || r.previous >= 2 {
        return false;
    }
    // The fallback must always name a previously admitted, bootable image.
    // Otherwise a damaged persistent record could "roll back" into Empty,
    // Booting, or Failed state.
    if r.slots[r.previous].state != .Good {
        return false;
    }
    // The active slot is either the known-good fallback itself or a candidate
    // currently being tried. Empty/Failed cannot be an active boot target.
    let active_state: SlotState = r.slots[r.active].state;
    return active_state == .Good || active_state == .Booting;
}

pub fn rollback_init(r: *mut RollbackState, version: u64) -> void {
    r.active = 0;
    r.previous = 0;
    r.slots[0].version = version;
    r.slots[0].state = .Good;
    r.slots[0].failed_boots = 0;
    r.slots[1].version = 0;
    r.slots[1].state = .Empty;
    r.slots[1].failed_boots = 0;
}

pub fn rollback_install_candidate(r: *mut RollbackState, version: u64) -> usize {
    if !rollback_state_valid(r) {
        return 2; // invalid-slot sentinel; never index or subtract corrupt state
    }
    let candidate: usize = 1 - r.active;
    r.previous = r.active;
    r.active = candidate;
    r.slots[candidate].version = version;
    r.slots[candidate].state = .Booting;
    r.slots[candidate].failed_boots = 0;
    return candidate;
}

pub fn rollback_install_verified_candidate(r: *mut RollbackState, bundle: VerifiedBundle) -> usize {
    let exact: bool = VerifiedBundle.has_exact_bytes(&bundle);
    let version: u64 = VerifiedBundle.version(&bundle);
    unsafe { forget_unchecked(bundle); } // installation consumes the admission token
    if !exact {
        return 2; // defensive guard: boot candidates require exact-byte admission
    }
    return rollback_install_candidate(r, version);
}

pub fn rollback_mark_boot_success(r: *mut RollbackState) -> void {
    if !rollback_state_valid(r) {
        return;
    }
    r.slots[r.active].state = .Good;
    r.slots[r.active].failed_boots = 0;
}

pub fn rollback_mark_boot_failed(r: *mut RollbackState, max_failures: u32) -> bool {
    if !rollback_state_valid(r) {
        return false;
    }
    if max_failures == 0 {
        return false;
    }
    if r.slots[r.active].failed_boots != 0xFFFF_FFFF {
        r.slots[r.active].failed_boots = r.slots[r.active].failed_boots + 1;
    }
    if r.slots[r.active].failed_boots >= max_failures {
        r.slots[r.active].state = .Failed;
        r.active = r.previous;
        return true;
    }
    r.slots[r.active].state = .Booting;
    return false;
}

pub fn rollback_active_version(r: *mut RollbackState) -> u64 {
    if !rollback_state_valid(r) {
        return 0;
    }
    return r.slots[r.active].version;
}

pub enum RebootReason {
    PowerOn,
    Clean,
    Watchdog,
    Panic,
    UpdateRollback,
}

pub struct RebootRecord {
    boot_epoch: u64,
    reason: RebootReason,
    detail: u32,
}

pub struct Watchdog {
    armed: bool,
    deadline_tick: u64,
    last_pet_tick: u64,
    timeout_ticks: u64,
}

pub fn watchdog_arm(w: *mut Watchdog, now: u64, timeout_ticks: u64) -> void {
    w.armed = true;
    w.last_pet_tick = now;
    w.timeout_ticks = timeout_ticks;
    w.deadline_tick = wrapping_add_u64(now, timeout_ticks);
}

pub fn watchdog_pet(w: *mut Watchdog, now: u64) -> void {
    if w.armed {
        w.last_pet_tick = now;
        w.deadline_tick = wrapping_add_u64(now, w.timeout_ticks);
    }
}

pub fn watchdog_expired(w: *mut Watchdog, now: u64) -> bool {
    if !w.armed {
        return false;
    }
    // Compare elapsed modular time rather than absolute samples. This remains
    // correct across one u64 wrap as long as the caller's timeout is within the
    // counter ambiguity window, which is the watchdog contract.
    return wrapping_sub_u64(now, w.last_pet_tick) >= w.timeout_ticks;
}

pub fn reboot_record(boot_epoch: u64, reason: RebootReason, detail: u32) -> RebootRecord {
    return .{ .boot_epoch = boot_epoch, .reason = reason, .detail = detail };
}

pub fn reboot_record_set(r: *mut RebootRecord, boot_epoch: u64, reason: RebootReason, detail: u32) -> void {
    r.boot_epoch = boot_epoch;
    r.reason = reason;
    r.detail = detail;
}

pub enum RuntimeAction {
    Allow,
    Throttle,
    Revoke,
    Kill,
}

pub enum AgentLifecycle {
    Running,
    Throttled,
    Revoked,
    Killed,
}

pub struct AgentControlState {
    lifecycle: AgentLifecycle,
    budget: u32,
}

pub fn agent_control(budget: u32) -> AgentControlState {
    return .{ .lifecycle = .Running, .budget = budget };
}

pub fn agent_control_init(s: *mut AgentControlState, budget: u32) -> void {
    s.lifecycle = .Running;
    s.budget = budget;
}

pub fn policy_apply_runtime_action(s: *mut AgentControlState, action: RuntimeAction) -> void {
    // Revoked and Killed are terminal. Later policy messages may be delayed or
    // duplicated, but they must never resurrect the subject.
    if s.lifecycle == .Revoked || s.lifecycle == .Killed {
        return;
    }
    switch action {
        .Allow => {}
        .Throttle => {
            s.lifecycle = .Throttled;
            if s.budget > 1 {
                s.budget = s.budget / 2;
            }
        }
        .Revoke => {
            s.lifecycle = .Revoked;
            s.budget = 0;
        }
        .Kill => {
            s.lifecycle = .Killed;
            s.budget = 0;
        }
    }
}
