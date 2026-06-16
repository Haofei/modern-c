// Shared virtio-rng entropy driver — see virtio_rng.h.
//
// This is the single source of truth for the device-id-4 probe that used to be
// duplicated inline in bearssl_smoke_runtime.c and https_get_runtime.c. The logic
// (register map, handshake, single device-writable queue, used-ring poll) is the
// union of those two copies, which were already identical apart from cosmetic
// macro names. No behavior change: same offsets, same queue size, same ~5s @
// 10 MHz timeout, same "zero the buffer first to prove the device wrote" step.
#include "virtio_rng.h"

// virtio-mmio transport register map (virtio 1.x, §4.2.2) — same map as std/virtio.mc.
#define VIRTIO_MMIO_BASE   0x10001000UL
#define VIRTIO_MMIO_STRIDE 0x1000UL
#define VIRTIO_MMIO_COUNT  8

#define VMR_MAGIC            0x000
#define VMR_VERSION          0x004
#define VMR_DEVICE_ID        0x008
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

#define VQ_SIZE 8
#define VRING_DESC_F_WRITE 2  // device-writable buffer

static inline uint32_t mmio_rd(volatile uint8_t *base, uint32_t off) {
    return *(volatile uint32_t *)(base + off);
}
static inline void mmio_wr(volatile uint8_t *base, uint32_t off, uint32_t val) {
    *(volatile uint32_t *)(base + off) = val;
}

// Split-virtqueue ring — same on-wire layout as std/virtqueue.mc.
typedef struct { uint64_t addr; uint32_t len; uint16_t flags; uint16_t next; } VrngDesc;
typedef struct { uint16_t flags; uint16_t idx; uint16_t ring[VQ_SIZE]; uint16_t used_event; } VrngAvail;
typedef struct { uint32_t id; uint32_t len; } VrngUsedElem;
typedef struct { uint16_t flags; uint16_t idx; VrngUsedElem ring[VQ_SIZE]; uint16_t avail_event; } VrngUsed;

static VrngDesc  g_rng_desc[VQ_SIZE] __attribute__((aligned(16)));
static VrngAvail g_rng_avail         __attribute__((aligned(2)));
static VrngUsed  g_rng_used          __attribute__((aligned(4)));
static uint16_t  g_rng_last_used = 0;

// DMA-visible scratch the device fills (BSS, identity-mapped).
static uint8_t g_rng_dma[256] __attribute__((aligned(16)));

volatile uint8_t *vrng_find(void) {
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

int vrng_init(volatile uint8_t *regs) {
    if (mmio_rd(regs, VMR_VERSION) != VIRTIO_VERSION_MODERN) return 0;

    // Reset, then handshake (§3.1.1).
    mmio_wr(regs, VMR_STATUS, 0);
    for (int s = 0; s < 100000 && mmio_rd(regs, VMR_STATUS) != 0; ++s) { }
    mmio_wr(regs, VMR_STATUS, STATUS_ACKNOWLEDGE);
    mmio_wr(regs, VMR_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // virtio-rng needs no feature bits; accept none.
    mmio_wr(regs, VMR_DRIVER_FEAT_SEL, 0);
    mmio_wr(regs, VMR_DRIVER_FEATURES, 0);
    mmio_wr(regs, VMR_DRIVER_FEAT_SEL, 1);
    mmio_wr(regs, VMR_DRIVER_FEATURES, 0);
    mmio_wr(regs, VMR_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);
    if ((mmio_rd(regs, VMR_STATUS) & STATUS_FEATURES_OK) != STATUS_FEATURES_OK) return 0;

    // Single requestq (queue 0).
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

uint32_t vrng_fill(volatile uint8_t *regs, uint8_t *dst, uint32_t len) {
    if (len > sizeof(g_rng_dma)) len = sizeof(g_rng_dma);
    for (uint32_t i = 0; i < len; ++i) g_rng_dma[i] = 0; // prove the device wrote

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

    uint64_t start = mc_read_ticks();
    while ((mc_read_ticks() - start) < 50000000ULL) { // ~5s at 10 MHz
        __sync_synchronize();
        if (g_rng_used.idx != g_rng_last_used) {
            VrngUsedElem *e = &g_rng_used.ring[g_rng_last_used % VQ_SIZE];
            uint32_t wrote = e->len;
            g_rng_last_used = (uint16_t)(g_rng_last_used + 1);
            // Ack any pending interrupt (we poll, but keep the device happy).
            uint32_t is = mmio_rd(regs, VMR_INTERRUPT_STATUS);
            if (is) mmio_wr(regs, VMR_INTERRUPT_ACK, is);
            uint32_t n = wrote < len ? wrote : len;
            for (uint32_t i = 0; i < n; ++i) dst[i] = g_rng_dma[i];
            return wrote;
        }
    }
    return 0;
}
