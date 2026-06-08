// Bare-metal riscv64 runtime for the virtio-blk driver: virtio-mmio device
// discovery, a small multi-slot DMA pool (the request chain needs three concurrent
// buffers), the virtqueue memory, and the CLINT time source. Hands the MC driver
// the device's MmioPtr + the virtqueue, prints the first bytes of the sector it
// reads.
#include <stdint.h>
#include <stddef.h>

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

typedef struct VringDesc { uint64_t addr; uint32_t len; uint16_t flags; uint16_t next; } VringDesc;
typedef struct DescTable { VringDesc d[8]; } DescTable;
typedef struct VringAvail { uint16_t flags; uint16_t idx; uint16_t ring[8]; uint16_t used_event; } VringAvail;
typedef struct UsedElem { uint32_t id; uint32_t len; } UsedElem;
typedef struct VringUsed { uint16_t flags; uint16_t idx; UsedElem ring[8]; uint16_t avail_event; } VringUsed;
typedef struct mc_array_u64_8 { uint64_t elems[8]; } mc_array_u64_8;
typedef struct Virtq {
    DescTable *desc; VringAvail *avail; VringUsed *used;
    uint16_t size; uint16_t free_head; uint16_t num_free; uint16_t last_used;
    mc_array_u64_8 inflight_addr;
} Virtq;
typedef struct CpuBuffer { uintptr_t dev_addr; uintptr_t cpu_addr; uintptr_t len; } CpuBuffer;
typedef struct DeviceBuffer { uintptr_t dev_addr; uintptr_t len; } DeviceBuffer;
typedef struct VirtioMmio VirtioMmio;

uint64_t blk_demo_run(volatile VirtioMmio *regs, Virtq *vq, uint64_t sector);

// std/dma platform primitives: a small bump pool (the blk chain holds three
// buffers — header/data/status — outstanding at once, unlike the net path's one).
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
DeviceBuffer mc_dma_clean_for_device(CpuBuffer b) { DeviceBuffer d = { b.dev_addr, b.len }; return d; }
CpuBuffer mc_dma_invalidate_for_cpu(DeviceBuffer b) { CpuBuffer c = { b.dev_addr, b.dev_addr, b.len }; return c; }

// std/time platform primitives.
#define CLINT_MTIME 0x0200BFF8UL
uint64_t mc_read_ticks(void) { return *(volatile uint64_t *)CLINT_MTIME; }
void mc_udelay(uint32_t us) {
    uint64_t t = mc_read_ticks() + (uint64_t)us * 10u;
    while (mc_read_ticks() < t) {}
}

#define UART ((volatile uint8_t *)0x10000000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
#define FINISHER ((volatile uint32_t *)0x00100000UL)

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
    *FINISHER = 0x5555;
    for (;;) {}
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
