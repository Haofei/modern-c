// Bare-metal riscv64 runtime for the virtio-blk driver: virtio-mmio device
// discovery, a small multi-slot DMA pool (the request chain needs three concurrent
// buffers), the virtqueue memory, and the CLINT time source. Hands the MC driver
// the device's MmioPtr + the virtqueue, prints the first bytes of the sector it
// reads.
#include <stdint.h>
#include "platform.h"        // mem/UART/halt/time
#include "platform_virtio.h" // vring + buffer structs, mc_dma_clean/invalidate

uint64_t blk_demo_run(volatile VirtioMmio *regs, Virtq *vq, uint64_t sector);

// std/dma pool: a small bump pool (the blk chain holds three buffers — header/data/
// status — outstanding at once, unlike the net path's one).
static uint8_t g_dma_pool[4096] __attribute__((aligned(16)));
static uintptr_t g_dma_off = 0;
CpuBuffer mc_dma_alloc(uintptr_t len) {
    uintptr_t a = (g_dma_off + 15) & ~(uintptr_t)15;
    if (a + len > sizeof(g_dma_pool)) for (;;) {}
    g_dma_off = a + len;
    for (uintptr_t i = 0; i < len; ++i) g_dma_pool[a + i] = 0;
    CpuBuffer b = { (uintptr_t)(g_dma_pool + a), (uintptr_t)(g_dma_pool + a), len };
    return b;
}
void mc_dma_free(CpuBuffer b) { (void)b; }

#define VIRTIO_MMIO_BASE 0x10001000UL
#define VIRTIO_MMIO_STRIDE 0x1000UL
#define VIRTIO_MMIO_COUNT 8
static DescTable  g_desc  __attribute__((aligned(16)));
static VringAvail g_avail __attribute__((aligned(2)));
static VringUsed  g_used  __attribute__((aligned(4)));

static volatile VirtioMmio *find_blk_device(void) {
    for (int i = 0; i < VIRTIO_MMIO_COUNT; ++i) {
        volatile uint32_t *slot = (volatile uint32_t *)(VIRTIO_MMIO_BASE + (uintptr_t)i * VIRTIO_MMIO_STRIDE);
        if (slot[0] == 0x74726976u && slot[2] == 2u) return (volatile VirtioMmio *)slot; // device_id 2 = blk
    }
    return 0;
}

__attribute__((used)) void test_main(void) {
    volatile VirtioMmio *regs = find_blk_device();
    if (!regs) { puts_("NODEV\n"); goto done; }
    puts_("blk: device found\n");

    static Virtq vq;
    vq.desc = &g_desc; vq.avail = &g_avail; vq.used = &g_used;

    uint64_t word = blk_demo_run(regs, &vq, 0);
    if (word == (uint64_t)-1) { puts_("BLK-INIT-FAIL\n"); goto done; }
    if (word == (uint64_t)-2) { puts_("BLK-READ-FAIL\n"); goto done; }

    // `word` is the first little-endian 32-bit word of sector 0.
    puts_("BLK-READ ");
    putc_((char)(word & 0xFF));
    putc_((char)((word >> 8) & 0xFF));
    putc_((char)((word >> 16) & 0xFF));
    putc_((char)((word >> 24) & 0xFF));
    puts_("\nBLK-OK\n");

done:
    mc_halt();
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
