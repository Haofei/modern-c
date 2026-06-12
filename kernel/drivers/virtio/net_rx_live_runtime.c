// Live-RX runtime: discovery + DMA + vrings (as net_runtime.c), then drive a real
// RX frame off the queue and route it through net_rx_deliver.
// platform's job — virtio-mmio discovery, a bump DMA allocator (multiple
// buffers), the vring memory — and drives the MC net stack through a real ARP
// exchange under QEMU user networking: send an ARP request for the gateway and
// receive slirp's reply on the RX queue. Reports over the QEMU `virt` 16550 UART.
#include <stdint.h>
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

// std/time platform primitives: monotonic ticks from the CLINT mtime counter
// (QEMU virt runs it at 10 MHz, so 10 ticks per microsecond).
#define CLINT_MTIME 0x0200BFF8UL
uint64_t mc_read_ticks(void) { return *(volatile uint64_t *)CLINT_MTIME; }
void mc_udelay(uint32_t us) {
    uint64_t target = *(volatile uint64_t *)CLINT_MTIME + (uint64_t)us * 10u;
    while (*(volatile uint64_t *)CLINT_MTIME < target) { }
}

// ----- virtqueue structs matching the MC layout (std/virtqueue.mc) -----
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

// The typed kernel entry (kernel/main.mc).
uintptr_t rx_live_get_frame(volatile VirtioMmio *regs, Virtq *rxq, Virtq *txq, uintptr_t buf, uintptr_t max);
void rx_route_init(uint16_t port);
uint32_t rx_route(uintptr_t buf, uintptr_t len);
static uint8_t framebuf[256];

// ----- std/dma platform primitives: a bump allocator over one DMA pool -----
// Multiple buffers can be outstanding (RX ring + TX frames). A bump allocator
// never aliases live buffers; `free` is a no-op (the pool is one-shot for this
// smoke test). Exhaustion halts rather than overruns.
static uint8_t g_dma_pool[65536] __attribute__((aligned(16)));
static uintptr_t g_dma_off = 0;
uintptr_t mc_dma_alloc_base(uintptr_t len) {
    uintptr_t a = (len + 15u) & ~(uintptr_t)15u; // 16-byte aligned
    if (g_dma_off + a > sizeof(g_dma_pool)) {
        for (;;) {
        } // pool exhausted
    }
    uint8_t *p = g_dma_pool + g_dma_off;
    g_dma_off += a;
    for (uintptr_t i = 0; i < len; ++i) p[i] = 0;
    return (uintptr_t)p;
}
void mc_dma_free_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; }
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
#define VIRTIO_MMIO_BASE 0x10001000UL
#define VIRTIO_MMIO_STRIDE 0x1000UL
#define VIRTIO_MMIO_COUNT 8

// Separate vring memory for the RX (queue 0) and TX (queue 1) queues.
static DescTable  g_rx_desc  __attribute__((aligned(16)));
static VringAvail g_rx_avail __attribute__((aligned(2)));
static VringUsed  g_rx_used  __attribute__((aligned(4)));
static DescTable  g_tx_desc  __attribute__((aligned(16)));
static VringAvail g_tx_avail __attribute__((aligned(2)));
static VringUsed  g_tx_used  __attribute__((aligned(4)));

// Static network identity (slirp's default 10.0.2.0/24, gateway .2, guest .15).
#define OUR_IP     0x0A00020Fu // 10.0.2.15
#define GATEWAY_IP 0x0A000202u // 10.0.2.2

// The platform provides device discovery (the MC `?MmioPtr` returned by a bus
// probe cannot yet flow into the `u32`-returning kernel_main — `if let` does not
// narrow `?MmioPtr`); the typed bus probe lives in kernel/drivers/virtio/mmio_bus.
static volatile VirtioMmio *find_net_device(void) {
    for (int i = 0; i < VIRTIO_MMIO_COUNT; ++i) {
        volatile uint32_t *slot = (volatile uint32_t *)(VIRTIO_MMIO_BASE + (uintptr_t)i * VIRTIO_MMIO_STRIDE);
        if (slot[0] == 0x74726976u && slot[2] == 1u) return (volatile VirtioMmio *)slot;
    }
    return 0;
}

__attribute__((used)) void test_main(void) {
    volatile VirtioMmio *regs = find_net_device();
    if (!regs) { puts_("NODEV\n"); goto done; }

    static Virtq rxq, txq; // BSS-zeroed
    rxq.desc = &g_rx_desc; rxq.avail = &g_rx_avail; rxq.used = &g_rx_used;
    txq.desc = &g_tx_desc; txq.avail = &g_tx_avail; txq.used = &g_tx_used;

    puts_("net-rx-live booting\n");
    rx_route_init(12345);
    // ARP the gateway; copy the real reply frame off the RX queue.
    uintptr_t n = rx_live_get_frame(regs, &rxq, &txq, (uintptr_t)framebuf, sizeof(framebuf));
    if (n == 0) { puts_("RX-NONE\n"); goto done; }
    uint32_t r = rx_route((uintptr_t)framebuf, n);   // through the production demux
    puts_("RX-FRAME len="); puthex((uint32_t)n);
    if (r & 0x80000000u) puts_(" UDP-DELIVERED"); else puts_(" routed");
    putc_('\n');
    puts_("NET-RX-LIVE-OK\n");

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
