// Chunked OTA transport + admission + rollback proof (production-readiness: OTA update).
//
// Exercises kernel/core/ota.mc (the chunk transport) feeding kernel/core/production_ops.mc
// (bundle admission + A/B rollback) END TO END on the real target under QEMU (bare M-mode,
// booted `-bios none`, reporting over the 16550 UART):
//
//   1. A synthetic kernel image (64 bytes) is hashed with the deterministic FNV-1a-32 that
//      the signed-boot demo carries as its image hash (ota_hash_bytes == signed_boot's).
//   2. GOOD DELIVERY: the image is delivered in N in-order chunks; each ota_chunk accepts,
//      ota_finish re-verifies the streamed digest == expected hash, THEN the reassembled
//      image is admitted by bundle_validate and installed as a rollback candidate
//        -> OTA-DELIVER-OK.
//   3. CORRUPT DELIVERY: one chunk byte is flipped; the length is still complete so ota_chunk
//      accepts every chunk, but ota_finish detects the digest mismatch -> HashMismatch.
//   4. MALFORMED DELIVERY (no trap): an out-of-order chunk (wrong offset) is rejected with
//      OutOfOrder, and an oversized chunk (past expected_len) with Overflow -> OTA-REJECT-OK.
//   5. OTA-OK prints only if every assertion above held.
//
// The harness (tools/fs/ota-test.sh) boots this once and asserts OTA-DELIVER-OK,
// OTA-REJECT-OK and OTA-OK.

import "tests/qemu/lib/test_report.mc";
import "kernel/core/production_ops.mc";
import "kernel/core/ota.mc";

const FINISHER: usize = 0x0010_0000; // SiFive test finisher
const FINISHER_HALT: u32 = 0x5555;

// Admission policy this device trusts (mirrors signed_boot_demo.mc).
const EXPECTED_ABI: u32 = 7;
const MIN_VERSION: u64 = 100;
const MAX_VERSION: u64 = 200;
const TRUSTED_KEY: u32 = 0x000A_11CE;
const GOOD_VERSION: u64 = 150;
const POLICY_VERSION: u64 = 3;
const SIG_LEN: usize = 256;

const IMAGE_LEN: usize = 64;
const CHUNK: usize = 8; // 8 chunks of 8 bytes

// OtaError discriminants flattened to a stable code so a single helper can assert the
// EXACT rejection reason (MC has no enum-to-int cast; switch maps them explicitly).
const OE_OUTOFORDER: u32 = 1;
const OE_OVERFLOW: u32 = 2;
const OE_INCOMPLETE: u32 = 3;
const OE_HASHMISMATCH: u32 = 4;

// The synthetic kernel image bytes (BSS, then filled) and a scratch corrupted copy.
global g_image: [64]u8;
global g_corrupt: [64]u8;
// OTA sessions and A/B rollback state (BSS-zeroed; init writes every field).
global g_sess: OtaSession;
global g_rb: RollbackState;

fn halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

fn ota_err_code(e: OtaError) -> u32 {
    switch e {
        .OutOfOrder => { return OE_OUTOFORDER; }
        .Overflow => { return OE_OVERFLOW; }
        .Incomplete => { return OE_INCOMPLETE; }
        .HashMismatch => { return OE_HASHMISMATCH; }
    }
}

// True iff the ota result is ok(_).
fn ota_is_ok(r: Result<bool, OtaError>) -> bool {
    switch r {
        ok(v) => { return true; }
        err(e) => { return false; }
    }
}

// True iff the ota result rejected with EXACTLY the expected error code.
fn ota_is_reject_with(r: Result<bool, OtaError>, want: u32) -> bool {
    switch r {
        ok(v) => { return false; }
        err(e) => {
            var matched: bool = false;
            if ota_err_code(e) == want {
                matched = true;
            }
            return matched;
        }
    }
}

// True iff bundle_validate accepted.
fn bundle_is_accept(r: Result<bool, BundleError>) -> bool {
    switch r {
        ok(v) => { return v; }
        err(e) => { return false; }
    }
}

// Deliver `buf` (address `base`, IMAGE_LEN bytes) into session `s` in CHUNK-sized in-order
// pieces. Returns true iff every ota_chunk accepted.
fn deliver_in_order(s: *mut OtaSession, base: usize) -> bool {
    var off: usize = 0;
    var ok_all: bool = true;
    while off < IMAGE_LEN {
        if !ota_is_ok(ota_chunk(s, off, phys(base + off) as *const u8, CHUNK)) {
            ok_all = false;
        }
        off = off + CHUNK;
    }
    return ok_all;
}

export fn test_main() -> void {
    // 1. Build the image buffer and compute its reference hash the signed-boot way.
    var i: usize = 0;
    while i < IMAGE_LEN {
        let byte: u8 = ((i * 7 + 11) & 0xFF) as u8;
        g_image[i] = byte;
        g_corrupt[i] = byte;
        i = i + 1;
    }
    let base: usize = (&g_image[0]) as usize;
    let img_hash: u64 = ota_hash_bytes(base, IMAGE_LEN);

    var all_ok: bool = true;

    // 2. GOOD DELIVERY: reassemble in-order chunks, verify digest, admit + install.
    ota_begin(&g_sess, IMAGE_LEN, img_hash);
    var deliver_ok: bool = deliver_in_order(&g_sess, base);
    if !ota_is_ok(ota_finish(&g_sess)) {
        deliver_ok = false; // digest must verify over the reassembled image
    }
    if deliver_ok {
        var good: BundleHeader = bundle_header_init(.Kernel, GOOD_VERSION, EXPECTED_ABI, POLICY_VERSION, TRUSTED_KEY, img_hash, SIG_LEN);
        if bundle_is_accept(bundle_validate(&good, EXPECTED_ABI, MIN_VERSION, MAX_VERSION, TRUSTED_KEY, .Valid)) {
            rollback_init(&g_rb, GOOD_VERSION);
            let cand: usize = rollback_install_candidate(&g_rb, 160);
            if rollback_active_version(&g_rb) == 160 {
                uputs("OTA-DELIVER-OK\n");
            } else {
                uputs("OTA-INSTALL-FAIL\n");
                all_ok = false;
            }
        } else {
            uputs("OTA-ADMIT-FAIL\n");
            all_ok = false;
        }
    } else {
        uputs("OTA-DELIVER-FAIL\n");
        all_ok = false;
    }

    // 3. CORRUPT DELIVERY: flip one byte; every chunk still accepts (length is intact) but
    //    ota_finish must catch the digest mismatch.
    g_corrupt[20] = (g_corrupt[20] ^ 0xFF) as u8;
    let cbase: usize = (&g_corrupt[0]) as usize;
    ota_begin(&g_sess, IMAGE_LEN, img_hash);
    let cdeliver: bool = deliver_in_order(&g_sess, cbase);
    if !cdeliver {
        all_ok = false; // a length-complete corrupt image still accepts chunk-by-chunk
    }
    if !ota_is_reject_with(ota_finish(&g_sess), OE_HASHMISMATCH) {
        uputs("OTA-CORRUPT-FAIL\n");
        all_ok = false;
    }

    // 4a. MALFORMED: out-of-order chunk (offset 0 accepted, then a jump to offset 32 with 0
    //     already consumed => wrong offset) is rejected WITHOUT trapping.
    ota_begin(&g_sess, IMAGE_LEN, img_hash);
    if !ota_is_ok(ota_chunk(&g_sess, 0, phys(base) as *const u8, CHUNK)) {
        all_ok = false;
    }
    // received == CHUNK now; supplying offset 32 is out of order.
    if !ota_is_reject_with(ota_chunk(&g_sess, 32, phys(base + 32) as *const u8, CHUNK), OE_OUTOFORDER) {
        uputs("OTA-OOO-FAIL\n");
        all_ok = false;
    }

    // 4b. MALFORMED: an oversized chunk that would run past expected_len is rejected with
    //     Overflow (overflow-safe capacity check, no wrap, no trap).
    ota_begin(&g_sess, IMAGE_LEN, img_hash);
    if !ota_is_reject_with(ota_chunk(&g_sess, 0, phys(base) as *const u8, IMAGE_LEN + 8), OE_OVERFLOW) {
        uputs("OTA-OVERFLOW-FAIL\n");
        all_ok = false;
    }

    uputs("OTA-REJECT-OK\n");

    if all_ok {
        uputs("OTA-OK\n");
    } else {
        uputs("OTA-FAIL\n");
    }
    halt();
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode; pin `_start` there.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
