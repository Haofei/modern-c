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

// ------------------------------------------------------------------ libc shims
// Freestanding libc primitives BearSSL and the compiler reference. BearSSL needs
// memcpy/memmove/memset/strlen (declared via the freestanding string.h shim);
// the compiler may also emit memcpy/memset for struct copies/zeroing.
void *memset(void *d, int c, size_t n) {
    uint8_t *p = (uint8_t *)d;
    for (size_t i = 0; i < n; ++i) p[i] = (uint8_t)c;
    return d;
}
void *memcpy(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d; const uint8_t *sp = (const uint8_t *)s;
    for (size_t i = 0; i < n; ++i) dp[i] = sp[i];
    return d;
}
void *memmove(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d; const uint8_t *sp = (const uint8_t *)s;
    if (dp == sp || n == 0) return d;
    if (dp < sp) {
        for (size_t i = 0; i < n; ++i) dp[i] = sp[i];
    } else {
        for (size_t i = n; i != 0; --i) dp[i - 1] = sp[i - 1];
    }
    return d;
}
int memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *pa = (const uint8_t *)a, *pb = (const uint8_t *)b;
    for (size_t i = 0; i < n; ++i) {
        if (pa[i] != pb[i]) return (int)pa[i] - (int)pb[i];
    }
    return 0;
}
size_t strlen(const char *s) {
    const char *p = s;
    while (*p) ++p;
    return (size_t)(p - s);
}

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

// -------------------------------------------------------- virtio-mmio transport
// virtio-mmio register offsets (virtio 1.x, 4.2.2) -- same map as std/virtio.mc.
#define VIRTIO_MMIO_BASE   0x10001000UL
#define VIRTIO_MMIO_STRIDE 0x1000UL
#define VIRTIO_MMIO_COUNT  8

#define VMR_MAGIC            0x000
#define VMR_VERSION          0x004
#define VMR_DEVICE_ID        0x008
#define VMR_DEVICE_FEATURES  0x010
#define VMR_DEVICE_FEAT_SEL  0x014
#define VMR_DRIVER_FEATURES  0x020
#define VMR_DRIVER_FEAT_SEL  0x024
#define VMR_QUEUE_SEL        0x030
#define VMR_QUEUE_NUM_MAX    0x034
#define VMR_QUEUE_NUM        0x038
#define VMR_QUEUE_READY      0x044
#define VMR_QUEUE_NOTIFY     0x050
#define VMR_INTERRUPT_STATUS 0x060
#define VMR_INTERRUPT_ACK    0x064
#define VMR_STATUS           0x070
#define VMR_QUEUE_DESC_LOW   0x080
#define VMR_QUEUE_DESC_HIGH  0x084
#define VMR_QUEUE_DRV_LOW    0x090
#define VMR_QUEUE_DRV_HIGH   0x094
#define VMR_QUEUE_DEV_LOW    0x0a0
#define VMR_QUEUE_DEV_HIGH   0x0a4

#define VIRTIO_MAGIC          0x74726976u
#define VIRTIO_VERSION_MODERN 2u
#define VIRTIO_DEVICE_ID_RNG  4u   // entropy device

#define STATUS_ACKNOWLEDGE 1u
#define STATUS_DRIVER      2u
#define STATUS_DRIVER_OK   4u
#define STATUS_FEATURES_OK 8u
#define STATUS_FAILED      128u

static inline uint32_t mmio_rd(volatile uint8_t *base, uint32_t off) {
    return *(volatile uint32_t *)(base + off);
}
static inline void mmio_wr(volatile uint8_t *base, uint32_t off, uint32_t val) {
    *(volatile uint32_t *)(base + off) = val;
}

// --------------------------------------------------------- split-virtqueue ring
// Single device-writable queue, size 8. Same on-wire layout as std/virtqueue.mc.
#define VQ_SIZE 8
#define VRING_DESC_F_WRITE 2  // device writes into this buffer (device-writable)

typedef struct { uint64_t addr; uint32_t len; uint16_t flags; uint16_t next; } VringDesc;
typedef struct { uint16_t flags; uint16_t idx; uint16_t ring[VQ_SIZE]; uint16_t used_event; } VringAvail;
typedef struct { uint32_t id; uint32_t len; } VringUsedElem;
typedef struct { uint16_t flags; uint16_t idx; VringUsedElem ring[VQ_SIZE]; uint16_t avail_event; } VringUsed;

static VringDesc  g_rng_desc[VQ_SIZE] __attribute__((aligned(16)));
static VringAvail g_rng_avail         __attribute__((aligned(2)));
static VringUsed  g_rng_used          __attribute__((aligned(4)));
static uint16_t   g_rng_last_used = 0;

// Scan the virtio-mmio slots for an entropy device (device-id 4).
static volatile uint8_t *find_rng_device(void) {
    for (int i = 0; i < VIRTIO_MMIO_COUNT; ++i) {
        volatile uint8_t *base =
            (volatile uint8_t *)(VIRTIO_MMIO_BASE + (uintptr_t)i * VIRTIO_MMIO_STRIDE);
        if (mmio_rd(base, VMR_MAGIC) == VIRTIO_MAGIC &&
            mmio_rd(base, VMR_DEVICE_ID) == VIRTIO_DEVICE_ID_RNG) {
            return base;
        }
    }
    return 0;
}

// virtio-rng has no required feature bits; we accept the intersection (= 0 wanted).
// Returns 1 on success.
static int rng_init(volatile uint8_t *regs) {
    if (mmio_rd(regs, VMR_VERSION) != VIRTIO_VERSION_MODERN) return 0;

    // Reset, then handshake (3.1.1).
    mmio_wr(regs, VMR_STATUS, 0);
    for (int s = 0; s < 100000 && mmio_rd(regs, VMR_STATUS) != 0; ++s) { }
    mmio_wr(regs, VMR_STATUS, STATUS_ACKNOWLEDGE);
    mmio_wr(regs, VMR_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // We require no features; accept none.
    mmio_wr(regs, VMR_DRIVER_FEAT_SEL, 0);
    mmio_wr(regs, VMR_DRIVER_FEATURES, 0);
    mmio_wr(regs, VMR_DRIVER_FEAT_SEL, 1);
    mmio_wr(regs, VMR_DRIVER_FEATURES, 0);
    mmio_wr(regs, VMR_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);
    if ((mmio_rd(regs, VMR_STATUS) & STATUS_FEATURES_OK) != STATUS_FEATURES_OK) return 0;

    // Set up the single requestq (queue 0).
    mmio_wr(regs, VMR_QUEUE_SEL, 0);
    uint32_t max = mmio_rd(regs, VMR_QUEUE_NUM_MAX);
    if (max == 0) return 0;
    uint32_t size = max < VQ_SIZE ? max : VQ_SIZE;
    mmio_wr(regs, VMR_QUEUE_NUM, size);

    g_rng_avail.idx = 0; g_rng_avail.flags = 0;
    g_rng_used.idx = 0;  g_rng_used.flags = 0;
    g_rng_last_used = 0;

    uint64_t desc_a  = (uint64_t)(uintptr_t)&g_rng_desc[0];
    uint64_t avail_a = (uint64_t)(uintptr_t)&g_rng_avail;
    uint64_t used_a  = (uint64_t)(uintptr_t)&g_rng_used;
    mmio_wr(regs, VMR_QUEUE_DESC_LOW,  (uint32_t)desc_a);
    mmio_wr(regs, VMR_QUEUE_DESC_HIGH, (uint32_t)(desc_a >> 32));
    mmio_wr(regs, VMR_QUEUE_DRV_LOW,   (uint32_t)avail_a);
    mmio_wr(regs, VMR_QUEUE_DRV_HIGH,  (uint32_t)(avail_a >> 32));
    mmio_wr(regs, VMR_QUEUE_DEV_LOW,   (uint32_t)used_a);
    mmio_wr(regs, VMR_QUEUE_DEV_HIGH,  (uint32_t)(used_a >> 32));
    __sync_synchronize();
    mmio_wr(regs, VMR_QUEUE_READY, 1);

    mmio_wr(regs, VMR_STATUS,
            STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);
    return 1;
}

// A DMA-visible scratch buffer for the device to fill (BSS, identity-mapped).
static uint8_t g_rng_dma[256] __attribute__((aligned(16)));

// Post `len` bytes of g_rng_dma as a device-writable buffer, kick, and spin until
// the device returns a used-ring entry. Returns the number of bytes the device
// wrote (0 on timeout / error). Bytes land in g_rng_dma.
static uint32_t rng_fill(volatile uint8_t *regs, uint32_t len) {
    if (len > sizeof(g_rng_dma)) len = sizeof(g_rng_dma);
    for (uint32_t i = 0; i < len; ++i) g_rng_dma[i] = 0; // prove the device wrote

    // Descriptor 0: one device-writable buffer.
    g_rng_desc[0].addr  = (uint64_t)(uintptr_t)&g_rng_dma[0];
    g_rng_desc[0].len   = len;
    g_rng_desc[0].flags = VRING_DESC_F_WRITE;
    g_rng_desc[0].next  = 0;

    uint16_t avail_slot = (uint16_t)(g_rng_avail.idx % VQ_SIZE);
    g_rng_avail.ring[avail_slot] = 0; // descriptor index 0
    __sync_synchronize();
    g_rng_avail.idx = (uint16_t)(g_rng_avail.idx + 1);
    __sync_synchronize();

    mmio_wr(regs, VMR_QUEUE_NOTIFY, 0); // kick queue 0

    // Spin (real-time bounded) for the completion.
    uint64_t start = mc_read_ticks();
    while ((mc_read_ticks() - start) < 50000000ULL) { // ~5s at 10 MHz
        __sync_synchronize();
        if (g_rng_used.idx != g_rng_last_used) {
            VringUsedElem *e = &g_rng_used.ring[g_rng_last_used % VQ_SIZE];
            uint32_t wrote = e->len;
            g_rng_last_used = (uint16_t)(g_rng_last_used + 1);
            // Ack any pending interrupt (we poll, but keep the device happy).
            uint32_t is = mmio_rd(regs, VMR_INTERRUPT_STATUS);
            if (is) mmio_wr(regs, VMR_INTERRUPT_ACK, is);
            return wrote;
        }
    }
    return 0;
}

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
        volatile uint8_t *rng = find_rng_device();
        if (!rng) {
            puts_("RNG-NODEV\n");
        } else if (!rng_init(rng)) {
            puts_("RNG-INIT-FAILED\n");
        } else {
            uint8_t a[16], b[16];
            uint32_t na = rng_fill(rng, 16);
            for (uint32_t i = 0; i < 16; ++i) a[i] = g_rng_dma[i];
            uint32_t nb = rng_fill(rng, 16);
            for (uint32_t i = 0; i < 16; ++i) b[i] = g_rng_dma[i];

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
