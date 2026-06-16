// BearSSL freestanding smoke-test runtime (Phase 1 of in-kernel TLS de-risking).
//
// Proves three things in a bare-metal riscv64 kernel under QEMU `-machine virt`,
// with NO TLS handshake yet:
//   1. BearSSL compiles + LINKS freestanding and its SHA-256 actually RUNS: we
//      compute SHA256("abc") with br_sha256_* and check it against the known
//      vector ba7816bf...f20015ad.  Prints SHA256-OK.
//   2. A real entropy source works: a minimal virtio-rng (virtio device-id 4)
//      driver pulls live random bytes into a buffer twice; we assert the bytes
//      are non-zero and the two reads DIFFER.  Prints RNG-OK.
//   3. A clock seam threads a build epoch (-D MC_BUILD_EPOCH=<unix-seconds>) into
//      the kernel for later X.509 validity checks.  Prints the epoch.
// On all of the above it prints BEARSSL-SMOKE-OK.
//
// Modeled on kernel/drivers/virtio/http_get_runtime.c (UART, virtio-mmio scan,
// DMA pool, _start). The virtio-rng driver is implemented here in C and follows
// the same split-virtqueue layout as std/virtqueue.mc + virtio_net.mc, but far
// simpler: one device-writable queue, no headers.
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

// Monotonic ticks from the CLINT mtime counter (QEMU virt: 10 MHz).
#define CLINT_MTIME 0x0200BFF8UL
uint64_t mc_read_ticks(void) { return *(volatile uint64_t *)CLINT_MTIME; }

// --------------------------------------------------------------------- UART I/O
#define UART ((volatile uint8_t *)0x10000000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void puthex64(uint64_t v) {
    putc_('0'); putc_('x');
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}
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

#define FINISHER ((volatile uint32_t *)0x00100000UL)

// -------------------------------------------------------- virtio-rng entropy
// The device-id-4 probe + handshake + random read now live in the shared driver
// kernel/drivers/virtio/virtio_rng.c (linked in by the test script). It depends
// on mc_read_ticks() above. vrng_fill() copies the device bytes into the caller's
// buffer (the inline copy used a shared global; behavior is otherwise identical).
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

__attribute__((used)) void test_main(void) {
    puts_("bearssl-smoke booting\n");
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

    *FINISHER = 0x5555;
    for (;;) { }
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
