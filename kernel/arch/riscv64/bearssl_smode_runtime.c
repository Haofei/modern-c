// S-mode/OpenSBI port of kernel/drivers/virtio/bearssl_smoke_runtime.c:
// revalidate the EXISTING freestanding BearSSL crypto stack (SHA-256 known-vector
// check) + the live virtio-rng entropy source under REAL OpenSBI firmware in
// S-mode, instead of the M-mode `-bios none` path.
//
// The ONLY differences vs bearssl_smoke_runtime.c are the boot seam (mirrors
// net_smode_runtime.c / blk_smode_runtime.c):
//   - OpenSBI enters in S-mode at 0x80200000 with a0=hartid/a1=dtb, so _start
//     preserves a0/a1 and calls s_entry(hartid, dtb).
//   - console output goes through the SBI legacy putchar ecall (EID 1) and halt
//     through the SBI shutdown ecall (EID 8), instead of the direct 0x10000000
//     16550 UART + the SiFive FINISHER @ 0x00100000 the M-mode runtime uses.
//   - the time source is the architectural `rdtime` CSR instead of the CLINT
//     mtime MMIO @ 0x0200_BFF8 that the M-mode runtime reads directly. Under
//     OpenSBI the CLINT/ACLINT mtime region is NOT PMP-mapped into S-mode
//     (OpenSBI owns the timer), so a direct CLINT load faults and resets the
//     hart. OpenSBI keeps the architectural `time` CSR in sync with the 10 MHz
//     QEMU virt mtimer, so the virtio_rng.c ~5s @ 10 MHz timeout is unchanged.
//
// satp is left 0 (Bare mode = flat physical). OpenSBI has programmed PMP so
// S-mode can touch RAM + MMIO, so the virtio-rng DMA and the virtio-mmio probe
// (magic 0x74726976 + device_id==4) work unchanged from the M-mode path.
//
// Everything else — BearSSL itself (compiled + linked identically by the test
// script), the SHA-256 known-vector check, the shared virtio_rng.c driver, and
// the clock seam (mc_build_epoch threaded in via -D MC_BUILD_EPOCH) — is
// IDENTICAL to bearssl_smoke_runtime.c. The success markers (SHA256-OK / RNG-OK /
// BEARSSL-SMOKE-OK) are byte-for-byte the same, so the S-mode harness greps for
// exactly the same strings as the M-mode gate.
#include <stdint.h>
#include <stddef.h>

#include "bearssl.h"

// ------------------------------------------------------------------- clock seam
// The build epoch (unix seconds), threaded in at compile time so later X.509
// validity checks have a "now". Just the seam for Phase 1: a constant the kernel
// can read. The test script passes -D MC_BUILD_EPOCH=$(date +%s).
#ifndef MC_BUILD_EPOCH
#define MC_BUILD_EPOCH 0
#endif
const uint64_t mc_build_epoch = (uint64_t)MC_BUILD_EPOCH;

// Monotonic ticks. The M-mode runtime reads the CLINT mtime MMIO @ 0x0200_BFF8
// directly, but under OpenSBI that ACLINT mtime region is NOT mapped into S-mode
// by PMP (OpenSBI owns the timer), so a direct CLINT MMIO load faults and resets
// the hart. The architectural S-mode time source is the `time` CSR (rdtime),
// which OpenSBI keeps in sync with the 10 MHz QEMU virt mtimer — same frequency,
// so virtio_rng.c's ~5s @ 10 MHz timeout is unchanged. This is the symbol the
// shared virtio_rng.c driver links against.
uint64_t mc_read_ticks(void) {
    uint64_t t;
    __asm__ volatile("rdtime %0" : "=r"(t));
    return t;
}

// --------------------------------------------------- SBI console + shutdown I/O
// One structured SBI ecall: extension id in a7, function id in a6, two args.
// (Mirrors net_smode_runtime.c / blk_smode_runtime.c.)
static long sbi_ecall(long ext, long fid, long arg0, long arg1) {
    register long a0 __asm__("a0") = arg0;
    register long a1 __asm__("a1") = arg1;
    register long a6 __asm__("a6") = fid;
    register long a7 __asm__("a7") = ext;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a6), "r"(a7) : "memory");
    return a0;
}
// Legacy SBI: console putchar = EID 1, shutdown = EID 8 (fid unused for legacy).
static void putc_(char c) { sbi_ecall(1, 0, (unsigned char)c, 0); }
static void sbi_shutdown(void) { sbi_ecall(8, 0, 0, 0); }
static void mc_halt(void) { sbi_shutdown(); for (;;) {} }

static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void puthex8(uint8_t b) {
    putc_("0123456789abcdef"[(b >> 4) & 0xf]);
    putc_("0123456789abcdef"[b & 0xf]);
}
static void putdec(uint64_t v) {
    char tmp[20]; int n = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n) putc_(tmp[--n]);
}

// -------------------------------------------------------- virtio-rng entropy
// The device-id-4 probe + handshake + random read live in the shared driver
// kernel/drivers/virtio/virtio_rng.c (linked in by the test script). It depends
// on mc_read_ticks() above (now backed by rdtime).
#include "virtio_rng.h"

// -------------------------------------------------------------- the smoke checks
// Known SHA-256 vector: SHA256("abc").
static const uint8_t SHA256_ABC[32] = {
    0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,
    0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad
};

static void print_hex_buf(const uint8_t *p, uint32_t n) {
    for (uint32_t i = 0; i < n; ++i) puthex8(p[i]);
}

// The crypto + entropy body — IDENTICAL to bearssl_smoke_runtime.c::test_main.
__attribute__((used)) void s_entry(uint64_t hartid, uint64_t dtb) {
    (void)hartid; (void)dtb;
    puts_("bearssl-smode booting under OpenSBI\n");
    puts_("BUILD-EPOCH="); putdec(mc_build_epoch); putc_('\n');

    int sha_ok = 0, rng_ok = 0;

    // ---- (1) SHA-256 via BearSSL, checked against the known vector ----
    {
        br_sha256_context ctx;
        uint8_t digest[32];
        br_sha256_init(&ctx);
        br_sha256_update(&ctx, "abc", 3);
        br_sha256_out(&ctx, digest);
        puts_("SHA256(abc)="); print_hex_buf(digest, 32); putc_('\n');
        if (memcmp(digest, SHA256_ABC, 32) == 0) {
            sha_ok = 1;
            puts_("SHA256-OK\n");
        } else {
            puts_("SHA256-MISMATCH\n");
        }
    }

    // ---- (2) live entropy via the virtio-rng device, two differing reads ----
    {
        volatile uint8_t *rng = vrng_find();
        if (!rng) {
            puts_("RNG-NODEV\n");
        } else if (!vrng_init(rng)) {
            puts_("RNG-INIT-FAILED\n");
        } else {
            uint8_t a[16], b[16];
            uint32_t na = vrng_fill(rng, a, 16);
            uint32_t nb = vrng_fill(rng, b, 16);

            puts_("RNG1="); print_hex_buf(a, 16); putc_('\n');
            puts_("RNG2="); print_hex_buf(b, 16); putc_('\n');

            int a_nonzero = 0, b_nonzero = 0;
            for (int i = 0; i < 16; ++i) { if (a[i]) a_nonzero = 1; if (b[i]) b_nonzero = 1; }
            int differ = (memcmp(a, b, 16) != 0);

            if (na >= 16 && nb >= 16 && a_nonzero && b_nonzero && differ) {
                rng_ok = 1;
                puts_("RNG-OK\n");
            } else {
                puts_("RNG-BAD ");
                if (!(na >= 16 && nb >= 16)) puts_("(short) ");
                if (!a_nonzero || !b_nonzero) puts_("(zero) ");
                if (!differ) puts_("(same) ");
                putc_('\n');
            }
        }
    }

    if (sha_ok && rng_ok) {
        puts_("BEARSSL-SMOKE-OK\n");
    } else {
        puts_("BEARSSL-SMOKE-FAILED\n");
    }

    mc_halt();
}

// OpenSBI enters here in S-mode with a0=hartid, a1=dtb. Set the stack but DO NOT
// clobber a0/a1 before the call, so s_entry receives them as its first two args.
__attribute__((naked, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call s_entry\n"
        "1: j 1b\n");
}
