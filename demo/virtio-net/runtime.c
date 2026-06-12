// Bare-metal riscv64 runtime for the virtio-net driver. Does the platform's job
// (virtio-mmio device discovery + DMA memory) and hands the MC driver the
// device's MmioPtr plus the virtqueue memory. The MC driver speaks the virtio
// protocol. Reports progress over the QEMU `virt` 16550 UART.
#include <stdint.h>

// CLINT time source (std/time externs; needed now that std/virtqueue uses vq_wait_used).
#define CLINT_MTIME 0x0200BFF8UL
uint64_t mc_read_ticks(void) { return *(volatile uint64_t *)CLINT_MTIME; }
void mc_udelay(uint32_t us) { uint64_t t = mc_read_ticks() + (uint64_t)us * 10u; while (mc_read_ticks() < t) {} }
#include <stddef.h>

// Freestanding libc primitives the compiler may emit (struct copies/zeroing).
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

// ----- virtqueue structs matching the MC layout (virtio_net.mc / virtio spec) -
typedef struct VringDesc { uint64_t addr; uint32_t len; uint16_t flags; uint16_t next; } VringDesc;
typedef struct DescTable { VringDesc d[8]; } DescTable;
typedef struct VringAvail { uint16_t flags; uint16_t idx; uint16_t ring[8]; uint16_t used_event; } VringAvail;
typedef struct UsedElem { uint32_t id; uint32_t len; } UsedElem;
typedef struct VringUsed { uint16_t flags; uint16_t idx; UsedElem ring[8]; uint16_t avail_event; } VringUsed;
// The driver-side virtqueue handle (std/virtqueue.mc Virtq) — free-list +
// in-flight record. MC lowers `[8]u64` to a struct-wrapped array.
typedef struct mc_array_u64_8 { uint64_t elems[8]; } mc_array_u64_8;
typedef struct Virtq {
    DescTable *desc; VringAvail *avail; VringUsed *used;
    uint16_t size; uint16_t free_head; uint16_t num_free; uint16_t last_used;
    mc_array_u64_8 inflight_addr;
} Virtq;
// std/dma move handles (erased to plain structs at the boundary).
typedef struct CpuBuffer { uintptr_t dev_addr; uintptr_t cpu_addr; uintptr_t len; } CpuBuffer;
typedef struct DeviceBuffer { uintptr_t dev_addr; uintptr_t len; } DeviceBuffer;
typedef struct VirtioMmio VirtioMmio;

// The MC driver entry points.
int nic_init(volatile VirtioMmio *regs, Virtq *txq);
int nic_transmit(volatile VirtioMmio *regs, Virtq *txq, uint16_t payload_len);

// ----- std/dma platform primitives: a single-slot, zeroed, aligned frame pool --
// Honors the linear contract the MC types promise: one outstanding allocation,
// length must fit — otherwise halt rather than alias the pool.
static uint8_t g_dma_pool[2048] __attribute__((aligned(16)));
static int g_dma_in_use = 0;
uintptr_t mc_dma_alloc_base(uintptr_t len) {
    if (len > sizeof(g_dma_pool) || g_dma_in_use) {
        for (;;) {
        } // contract violation
    }
    g_dma_in_use = 1;
    for (uintptr_t i = 0; i < len; ++i) g_dma_pool[i] = 0; // zero the frame
    return (uintptr_t)g_dma_pool;
}
void mc_dma_free_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; g_dma_in_use = 0; }
void mc_dma_clean_for_device_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; }
uintptr_t mc_dma_invalidate_for_cpu_base(uintptr_t dev_addr, uintptr_t len) { (void)len; return dev_addr; }

// ----- UART (QEMU virt 16550 at 0x1000_0000) -----
#define UART ((volatile uint8_t *)0x10000000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void puthex(uint64_t v) {
    putc_('0'); putc_('x');
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}

#define FINISHER ((volatile uint32_t *)0x00100000UL)

// virtio-mmio transports on QEMU `virt`: 8 slots of 0x1000 at 0x1000_1000.
#define VIRTIO_MMIO_BASE 0x10001000UL
#define VIRTIO_MMIO_STRIDE 0x1000UL
#define VIRTIO_MMIO_COUNT 8

// vring memory (identity-mapped; alignment per virtio 1.0).
static DescTable  g_desc  __attribute__((aligned(16)));
static VringAvail g_avail __attribute__((aligned(2)));
static VringUsed  g_used  __attribute__((aligned(4)));

static volatile VirtioMmio *find_net_device(void) {
    for (int i = 0; i < VIRTIO_MMIO_COUNT; ++i) {
        volatile uint32_t *slot = (volatile uint32_t *)(VIRTIO_MMIO_BASE + (uintptr_t)i * VIRTIO_MMIO_STRIDE);
        uint32_t magic = slot[0];       // 0x000
        uint32_t device_id = slot[2];   // 0x008
        if (magic == 0x74726976u && device_id == 1u) {
            return (volatile VirtioMmio *)slot;
        }
    }
    return 0;
}

__attribute__((used)) void test_main(void) {
    volatile VirtioMmio *regs = find_net_device();
    if (!regs) { puts_("NODEV\n"); goto done; }
    puts_("DISC "); puthex((uint64_t)(uintptr_t)regs); putc_('\n');

    static Virtq txq; // zero-initialized in BSS (no large stack-init memcpy)
    txq.desc = &g_desc; txq.avail = &g_avail; txq.used = &g_used;
    if (!nic_init(regs, &txq)) { puts_("INIT-FAIL\n"); goto done; }
    puts_("INIT-OK\n");

    if (!nic_transmit(regs, &txq, 60)) { puts_("TX-FAIL\n"); goto done; }
    puts_("VIRTIO-TX-OK\n");

done:
    *FINISHER = 0x5555;
    for (;;) {
    }
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
