// BUNDLE / OTA ADMISSION FUZZER — drive the signed-update admission surface
// (kernel/core/production_ops.mc) over ADVERSARIAL headers and random op sequences and prove it is
// TOTAL: every call returns a typed result (accept or a typed BundleError) or a well-defined state
// transition — never a trap/crash (production-readiness §4.7 hardening polish, P6).
//
// The bundle header is the first thing the kernel decodes about an untrusted OTA image; the rollback
// state machine drives A/B slot promotion/demotion after a boot. Both are attacker-influenced (a
// hostile update server controls the header bytes; boot outcomes drive the rollback ops). This
// fuzzer feeds RANDOM field values to `bundle_validate` and RANDOM op sequences to the rollback
// machine and asserts:
//   * bundle_validate always returns — a garbage header is rejected with a typed BundleError
//     (fail-closed), and ONLY an exactly-valid+signed header is accepted;
//   * the rollback machine's active/previous slot indices ALWAYS stay in {0,1} — a bug that let an
//     index escape would make `1 - active` (usize, CHECKED) underflow-trap or `slots[active]`
//     over-read, so completing thousands of random op sequences without a trap is the property.
//
// Host-driver oracle (tools/lib/host-drivers/bundle-fuzz-test.c): if any call trapped, the driver
// process aborts (SIGABRT) before printing success. DETERMINISTIC — a seeded xorshift PRNG, no
// wall-clock, no Math.random — so it is a reliable CI gate (same inputs every run).

import "kernel/core/production_ops.mc";
import "std/math.mc"; // wrapping_shl_u32 (checked `<<` would trap on the xorshift bit spill)

// The trusted admission parameters the kernel would enforce for a real update.
const EXPECTED_ABI: u32 = 7;
const MIN_VER: u64 = 100;
const MAX_VER: u64 = 200;
const TRUSTED_KEY: u32 = 0x000A_11CE;
const GOOD_VER: u64 = 150;      // squarely inside [MIN_VER, MAX_VER]
const GOOD_SIG_LEN: usize = 64;

global g_rb: RollbackState;

// xorshift32 PRNG (deterministic, seedable). The left shifts use the wrapping helper because MC's
// `<<` is checked — xorshift relies on bits spilling away, not trapping.
fn rng(state: u32) -> u32 {
    var x: u32 = state;
    x = x ^ wrapping_shl_u32(x, 13);
    x = x ^ (x >> 17);
    x = x ^ wrapping_shl_u32(x, 5);
    return x;
}

fn kind_of(r: u32) -> BundleKind {
    let m: u32 = r % 3;
    if m == 0 { return .Kernel; }
    if m == 1 { return .Policy; }
    return .Agent;
}

fn sig_of(r: u32) -> SignatureStatus {
    let m: u32 = r % 4;
    if m == 0 { return .Valid; }
    if m == 1 { return .Missing; }
    if m == 2 { return .Bad; }
    return .WrongKey;
}

// 0 iff bundle_validate accepted the header, 1 iff it returned a typed error. Either way it MUST
// return (no trap): bundle_validate is pure comparison logic over the header.
fn bv(h: *BundleHeader, sig: SignatureStatus) -> u32 {
    switch bundle_validate(h, EXPECTED_ABI, MIN_VER, MAX_VER, TRUSTED_KEY, sig) {
        ok(v) => { return 0; }
        err(e) => { return 1; }
    }
}

// A perfectly valid, signed header. Its own accept path (fuzz_valid) proves the fuzzer's positive
// case is real; each fuzz_corrupt(which) perturbs exactly one field off this baseline.
fn make_valid() -> BundleHeader {
    return bundle_header_init(.Kernel, GOOD_VER, EXPECTED_ABI, 1, TRUSTED_KEY, 0xDEAD_BEEF, GOOD_SIG_LEN);
}

// The valid+signed header MUST be accepted (returns 0). Anchors the accept path.
export fn fuzz_valid() -> u32 {
    var h: BundleHeader = make_valid();
    return bv(&h, .Valid);
}

// Corrupt exactly ONE admission-relevant field of the valid header (or the sig), and it MUST be
// rejected (returns 1 = clean typed error, never a trap). `which` selects the field; the driver
// sweeps every value and requires 1 each time — teeth: a dropped guard makes one return 0 (accept).
export fn fuzz_corrupt(which: u32) -> u32 {
    var h: BundleHeader = make_valid();
    var sig: SignatureStatus = .Valid;
    let w: u32 = which % 7;
    if w == 0 { h.magic = 0xBAD0_0000; }          // wrong magic -> BadMagic
    if w == 1 { h.abi_version = EXPECTED_ABI + 1; } // wrong ABI  -> BadAbi
    if w == 2 { h.version = MIN_VER - 1; }          // below range -> BadVersion
    if w == 3 { h.version = MAX_VER + 1; }          // above range -> BadVersion
    if w == 4 { h.key_id = TRUSTED_KEY + 1; }       // untrusted key -> WrongKey
    if w == 5 { h.signature_len = 0; }              // no signature  -> BadSignature
    if w == 6 { sig = .Missing; }                   // unsigned      -> BadSignature
    return bv(&h, sig);
}

// Feed a fully RANDOM header (each admission field independently randomized to straddle its
// accept/reject boundary) to bundle_validate. Returns 0 if accepted, 1 if rejected — either way it
// returns without trapping. The driver runs this over many seeds and requires BOTH outcomes to
// occur (both paths are real) with no trap.
export fn fuzz_bundle(seed: u32) -> u32 {
    var st: u32 = seed | 1;
    st = rng(st); let magic_r: u32 = st;
    st = rng(st); let kind_r: u32 = st;
    st = rng(st); let ver_r: u32 = st;
    st = rng(st); let abi_r: u32 = st;
    st = rng(st); let key_r: u32 = st;
    st = rng(st); let siglen_r: u32 = st;
    st = rng(st); let sig_r: u32 = st;
    st = rng(st); let hash_r: u32 = st;

    // version straddles [100, 229] so both in-range and above-range occur; abi straddles 7;
    // key is TRUSTED half the time; signature_len straddles 0.
    let version: u64 = MIN_VER + ((ver_r as u64) % 130);
    let abi: u32 = abi_r % 12;
    var key: u32 = key_r;
    if (key_r & 1) == 0 { key = TRUSTED_KEY; }
    let sig_len: usize = (siglen_r % 3) as usize;

    var h: BundleHeader = bundle_header_init(kind_of(kind_r), version, abi, 1, key, hash_r as u64, sig_len);
    // bundle_header_init always stamps the correct magic; corrupt it half the time to fuzz the
    // magic guard too.
    if (magic_r & 2) == 0 { h.magic = magic_r; }
    return bv(&h, sig_of(sig_r));
}

// Drive a RANDOM sequence of rollback ops (install candidate / mark boot success / mark boot failed)
// and assert the A/B slot invariant after every op: active and previous are ALWAYS a valid slot
// index (< 2). Returns 0 if the invariant held throughout, 1 if it was ever violated. The real
// safety property is NO TRAP: an escaped index would make `1 - active` (checked usize) underflow or
// `slots[active]` over-read and abort the driver before it could return.
export fn fuzz_rollback(seed: u32) -> u32 {
    rollback_init(&g_rb, 100);
    var st: u32 = seed | 1;
    var i: u32 = 0;
    while i < 96 {
        st = rng(st);
        let op: u32 = st % 3;
        if op == 0 {
            st = rng(st);
            let v: u64 = (st as u64) & 0xFFFF;
            let cand: usize = rollback_install_candidate(&g_rb, v);
            if cand > 1 { return 1; } // candidate slot must be the other valid slot
        } else {
            if op == 1 {
                rollback_mark_boot_success(&g_rb);
            } else {
                st = rng(st);
                let maxf: u32 = (st % 4) + 1;
                let rolled: bool = rollback_mark_boot_failed(&g_rb, maxf);
            }
        }
        if g_rb.active > 1 { return 1; }
        if g_rb.previous > 1 { return 1; }
        let _v: u64 = rollback_active_version(&g_rb); // indexes slots[active] — a total read (no trap)
        i = i + 1;
    }
    return 0;
}
