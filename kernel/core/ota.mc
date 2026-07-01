// kernel/core/ota — chunked OTA (over-the-air) update TRANSPORT.
//
// The admission + rollback control plane already exists in kernel/core/production_ops.mc
// (BundleHeader/bundle_validate, RollbackState/rollback_install_candidate). What that layer
// assumes is an image already in memory. This module supplies the missing TRANSPORT: an
// image arrives in arbitrary-sized CHUNKS (a network/flash stream), is reassembled in
// strict order, and a running hash over the reassembled bytes is verified against the
// expected image hash BEFORE the bytes are handed to bundle_validate + rollback install.
//
// The hash is the SAME deterministic FNV-1a-32 the signed-boot demo carries as its image
// hash (see tests/qemu/arch/signed_boot_demo.mc): identical offset basis and prime, so a
// streamed hash over in-order chunks equals a one-shot hash over the whole buffer. FNV-1a
// folds one byte at a time, which is exactly what a chunk state machine needs — no full
// buffer copy is required to compute the digest.
//
// All length arithmetic is overflow-safe: a chunk that would push `received` past
// `expected_len` is rejected (Overflow) rather than wrapping or trapping, and the
// remaining-capacity check is written as `len > expected_len - received` where the
// subtraction can never underflow because the invariant `received <= expected_len` holds.

// FNV-1a-32 constants — MUST match signed_boot_demo.mc so the digests are interchangeable.
const OTA_FNV_OFFSET: u32 = 0x811c9dc5;
const OTA_FNV_PRIME: u32 = 0x0100_0193;

enum OtaError {
    OutOfOrder,
    Overflow,
    Incomplete,
    HashMismatch,
}

struct OtaSession {
    expected_len: usize,
    received: usize,
    expected_hash: u64,
    hash_accum: u32,
    active: bool,
}

// u32*u32 fits in u64, so the product never trips the checked-overflow trap; truncating
// back to u32 gives the modular (wrapping) FNV multiply. Identical to signed_boot_demo's.
fn ota_wrap_mul_u32(a: u32, b: u32) -> u32 {
    return (((a as u64) * (b as u64)) & 0x0000_0000_FFFF_FFFF) as u32;
}

// Fold one byte into a running FNV-1a-32 accumulator.
fn ota_fnv_step(h: u32, byte: u8) -> u32 {
    let mixed: u32 = h ^ (byte as u32);
    return ota_wrap_mul_u32(mixed, OTA_FNV_PRIME);
}

// One-shot FNV-1a-32 over `len` bytes starting at raw address `base`, widened to u64.
// This is the reference digest a delivered image is checked against; it yields the same
// value as folding the identical bytes chunk-by-chunk through ota_chunk.
export fn ota_hash_bytes(base: usize, len: usize) -> u64 {
    var h: u32 = OTA_FNV_OFFSET;
    var i: usize = 0;
    while i < len {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        h = ota_fnv_step(h, b);
        i = i + 1;
    }
    return h as u64;
}

// Begin a delivery: record the expected total length and expected image hash, reset the
// running digest to the FNV basis, and arm the session.
export fn ota_begin(s: *mut OtaSession, expected_len: usize, expected_hash: u64) -> void {
    s.expected_len = expected_len;
    s.received = 0;
    s.expected_hash = expected_hash;
    s.hash_accum = OTA_FNV_OFFSET;
    s.active = true;
}

// Accept the chunk at byte `offset` of length `len` read from raw address `bytes_ptr`.
//
// Rejections (no trap, no state mutation on the error paths):
//   * OutOfOrder — offset != received (covers gaps, replays and overlaps).
//   * Overflow   — the chunk would carry `received` past `expected_len`.
// On success the chunk's bytes are folded into the running hash and `received` advances.
// Returns ok(true) once the whole expected length has been received, ok(false) otherwise.
export fn ota_chunk(s: *mut OtaSession, offset: usize, bytes_ptr: *const u8, len: usize) -> Result<bool, OtaError> {
    if !s.active {
        return err(.OutOfOrder);
    }
    if offset != s.received {
        return err(.OutOfOrder);
    }
    // Overflow-safe capacity check: `received <= expected_len` always holds, so the
    // subtraction cannot underflow, and we never wrap or trap on an oversized chunk.
    if len > s.expected_len - s.received {
        return err(.Overflow);
    }
    let base: usize = bytes_ptr as usize;
    var i: usize = 0;
    var h: u32 = s.hash_accum;
    while i < len {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        h = ota_fnv_step(h, b);
        i = i + 1;
    }
    s.hash_accum = h;
    s.received = s.received + len;
    if s.received == s.expected_len {
        return ok(true);
    }
    return ok(false);
}

// Finalize a delivery: require the full length was received and that the streamed digest
// equals the expected image hash. On success the caller may proceed to bundle_validate +
// rollback_install_candidate. Deactivates the session on success so it cannot be reused.
export fn ota_finish(s: *mut OtaSession) -> Result<bool, OtaError> {
    // Reject a session that was never begun or was already finalized. Without this a zeroed session
    // (received == expected_len == 0, hash_accum == expected_hash == 0) would spuriously finalize, and
    // a finished one could be re-finalized — violating the one-shot contract.
    if !s.active {
        return err(.Incomplete);
    }
    if s.received != s.expected_len {
        return err(.Incomplete);
    }
    if (s.hash_accum as u64) != s.expected_hash {
        return err(.HashMismatch);
    }
    s.active = false;
    return ok(true);
}
