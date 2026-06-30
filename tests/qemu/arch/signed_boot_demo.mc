// Signed kernel-image admission + rollback proof (production-readiness: secure boot).
//
// Exercises the bundle-admission and A/B rollback state machine in
// kernel/core/production_ops.mc END TO END on the real target under QEMU (bare M-mode,
// booted `-bios none`, reporting over the 16550 UART), not just as host unit logic:
//
//   1. Compute an IMAGE HASH over a byte buffer. No native MC hash primitive is linkable
//      into a freestanding image here (BearSSL is C + needs the TLS link infra), so per the
//      gate spec we use a deterministic FNV-1a-32 checksum AS THE IMAGE HASH for this demo.
//      The hash is carried in the BundleHeader and would be the value a signature covers.
//   2. bundle_validate ACCEPTS a correctly-signed, in-ABI, in-version-range bundle whose
//      key matches the trusted key id and whose SignatureStatus is Valid  -> SIGBOOT-ACCEPT.
//   3. bundle_validate REJECTS every tamper case with the RIGHT BundleError:
//      wrong key id, bad signature status, ABI mismatch, version below min, version above max.
//   4. Rollback: install a candidate, drive it to max_failures failed boots -> the state
//      machine rolls back (mark_boot_failed returns true) and the active version reverts to
//      the prior good image; a separate SUCCESS path COMMITS the candidate -> SIGBOOT-ROLLBACK-OK.
//   5. SIGNED-BOOT-OK prints only if every assertion above held.
//
// The harness (tools/fs/signed-boot-test.sh) boots this once and asserts all three markers.

import "tests/qemu/lib/test_report.mc";
import "kernel/core/production_ops.mc";
import "std/addr.mc";

const FINISHER: usize = 0x0010_0000; // SiFive test finisher
const FINISHER_HALT: u32 = 0x5555;

// Admission policy this device trusts.
const EXPECTED_ABI: u32 = 7;
const MIN_VERSION: u64 = 100;
const MAX_VERSION: u64 = 200;
const TRUSTED_KEY: u32 = 0x000A_11CE;
const GOOD_VERSION: u64 = 150; // inside [MIN_VERSION, MAX_VERSION]
const POLICY_VERSION: u64 = 3;
const SIG_LEN: usize = 256; // non-zero: an actual signature is attached

// BundleError discriminants flattened to a stable code so a single helper can assert
// the EXACT rejection reason (MC has no enum-to-int cast; switch maps them explicitly).
const E_BADMAGIC: u32 = 1;
const E_BADKIND: u32 = 2;
const E_BADABI: u32 = 3;
const E_BADVERSION: u32 = 4;
const E_BADSIG: u32 = 5;
const E_WRONGKEY: u32 = 6;

// FNV-1a-32 constants.
const FNV_OFFSET: u32 = 0x811c9dc5;
const FNV_PRIME: u32 = 0x0100_0193;

// The synthetic kernel image bytes the hash is computed over (BSS, then filled).
global g_image: [64]u8;
// A/B rollback state for the two scenarios (BSS-zeroed; init writes every field).
global g_rb_fail: RollbackState;
global g_rb_ok: RollbackState;

fn halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

// u32*u32 fits exactly in u64, so the product never trips the checked-overflow trap;
// truncating back to u32 gives the intended modular (wrapping) FNV multiply.
fn wrap_mul_u32(a: u32, b: u32) -> u32 {
    return (((a as u64) * (b as u64)) & 0x0000_0000_FFFF_FFFF) as u32;
}

// Deterministic FNV-1a-32 over the global image buffer, widened to the u64 image_hash
// field. (MC indexes only arrays/slices, not raw pointers, so it reads g_image directly.)
fn image_hash_fnv1a(len: usize) -> u64 {
    var h: u32 = FNV_OFFSET;
    var i: usize = 0;
    while i < len {
        h = h ^ (g_image[i] as u32);
        h = wrap_mul_u32(h, FNV_PRIME);
        i = i + 1;
    }
    return h as u64;
}

fn err_code(e: BundleError) -> u32 {
    switch e {
        .BadMagic => { return E_BADMAGIC; }
        .BadKind => { return E_BADKIND; }
        .BadAbi => { return E_BADABI; }
        .BadVersion => { return E_BADVERSION; }
        .BadSignature => { return E_BADSIG; }
        .WrongKey => { return E_WRONGKEY; }
    }
}

// True iff the validation accepted (ok(true)).
fn is_accept(r: Result<bool, BundleError>) -> bool {
    switch r {
        ok(v) => { return v; }
        err(e) => { return false; }
    }
}

// True iff the validation rejected with EXACTLY the expected error code.
fn is_reject_with(r: Result<bool, BundleError>, want: u32) -> bool {
    switch r {
        ok(v) => { return false; }
        err(e) => {
            var matched: bool = false;
            if err_code(e) == want {
                matched = true;
            }
            return matched;
        }
    }
}

export fn test_main() -> void {
    // 1. Build the image buffer and hash it.
    var i: usize = 0;
    while i < 64 {
        g_image[i] = ((i * 7 + 11) & 0xFF) as u8;
        i = i + 1;
    }
    let img_hash: u64 = image_hash_fnv1a(64);

    var all_ok: bool = true;

    // 2. ACCEPT: a correctly-signed, in-range, trusted-key kernel bundle.
    var good: BundleHeader = bundle_header_init(.Kernel, GOOD_VERSION, EXPECTED_ABI, POLICY_VERSION, TRUSTED_KEY, img_hash, SIG_LEN);
    if is_accept(bundle_validate(&good, EXPECTED_ABI, MIN_VERSION, MAX_VERSION, TRUSTED_KEY, .Valid)) {
        uputs("SIGBOOT-ACCEPT\n");
    } else {
        uputs("SIGBOOT-ACCEPT-FAIL\n");
        all_ok = false;
    }

    // 3a. REJECT: wrong key id (header signed by an untrusted key).
    var wrongkey: BundleHeader = bundle_header_init(.Kernel, GOOD_VERSION, EXPECTED_ABI, POLICY_VERSION, 0x0000_0BAD, img_hash, SIG_LEN);
    if !is_reject_with(bundle_validate(&wrongkey, EXPECTED_ABI, MIN_VERSION, MAX_VERSION, TRUSTED_KEY, .Valid), E_WRONGKEY) {
        uputs("SIGBOOT-WRONGKEY-FAIL\n");
        all_ok = false;
    }

    // 3b. REJECT: bad signature status (key/abi/version all fine, signature is forged).
    if !is_reject_with(bundle_validate(&good, EXPECTED_ABI, MIN_VERSION, MAX_VERSION, TRUSTED_KEY, .Bad), E_BADSIG) {
        uputs("SIGBOOT-BADSIG-FAIL\n");
        all_ok = false;
    }

    // 3c. REJECT: ABI mismatch (image built against a different kernel ABI).
    var wrongabi: BundleHeader = bundle_header_init(.Kernel, GOOD_VERSION, 99, POLICY_VERSION, TRUSTED_KEY, img_hash, SIG_LEN);
    if !is_reject_with(bundle_validate(&wrongabi, EXPECTED_ABI, MIN_VERSION, MAX_VERSION, TRUSTED_KEY, .Valid), E_BADABI) {
        uputs("SIGBOOT-ABI-FAIL\n");
        all_ok = false;
    }

    // 3d. REJECT: version below the minimum (anti-rollback floor / downgrade attack).
    var tooold: BundleHeader = bundle_header_init(.Kernel, 50, EXPECTED_ABI, POLICY_VERSION, TRUSTED_KEY, img_hash, SIG_LEN);
    if !is_reject_with(bundle_validate(&tooold, EXPECTED_ABI, MIN_VERSION, MAX_VERSION, TRUSTED_KEY, .Valid), E_BADVERSION) {
        uputs("SIGBOOT-MINVER-FAIL\n");
        all_ok = false;
    }

    // 3e. REJECT: version above the maximum (unknown future image).
    var toonew: BundleHeader = bundle_header_init(.Kernel, 250, EXPECTED_ABI, POLICY_VERSION, TRUSTED_KEY, img_hash, SIG_LEN);
    if !is_reject_with(bundle_validate(&toonew, EXPECTED_ABI, MIN_VERSION, MAX_VERSION, TRUSTED_KEY, .Valid), E_BADVERSION) {
        uputs("SIGBOOT-MAXVER-FAIL\n");
        all_ok = false;
    }

    // 4. ROLLBACK on failure: good v100 -> install candidate v101 -> drive to max_failures.
    let max_failures: u32 = 3;
    var rb_ok: bool = true;
    rollback_init(&g_rb_fail, 100);
    let cand: usize = rollback_install_candidate(&g_rb_fail, 101);
    if rollback_active_version(&g_rb_fail) != 101 {
        rb_ok = false;
    }
    var rolled: bool = false;
    var k: u32 = 0;
    while k < max_failures {
        rolled = rollback_mark_boot_failed(&g_rb_fail, max_failures);
        k = k + 1;
    }
    if !rolled {
        rb_ok = false; // the final failed boot must signal a rollback
    }
    if rollback_active_version(&g_rb_fail) != 100 {
        rb_ok = false; // active image must revert to the prior good version
    }

    // 4b. SUCCESS path COMMITS the candidate: good v100 -> install v102 -> boot success.
    rollback_init(&g_rb_ok, 100);
    let cand2: usize = rollback_install_candidate(&g_rb_ok, 102);
    rollback_mark_boot_success(&g_rb_ok);
    if rollback_active_version(&g_rb_ok) != 102 {
        rb_ok = false; // a successful boot keeps the new image
    }

    if rb_ok {
        uputs("SIGBOOT-ROLLBACK-OK\n");
    } else {
        uputs("SIGBOOT-ROLLBACK-FAIL\n");
        all_ok = false;
    }

    if all_ok {
        uputs("SIGNED-BOOT-OK\n");
    } else {
        uputs("SIGNED-BOOT-FAIL\n");
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
