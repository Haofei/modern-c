// HTTP-GET runtime: platform glue (virtio-mmio discovery, a bump DMA allocator,
// the vring memory) that drives the MC TCP/HTTP client (tests/qemu/net/http_get_demo)
// through a real outbound connection to a live HTTP server under QEMU user
// networking. Reports the captured response and HTTP-GET-OK over the QEMU `virt`
// 16550 UART. Modeled on net_rx_live_runtime.c.
#include <stdint.h>
#include <stddef.h>

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
// Mirrors std/virtqueue.mc `Virtq` exactly: the three vring pointers, the negotiated
// size + free-list cursors, and the in-flight record (addr/len/present per descriptor).
// The C struct MUST match the MC field order/layout or the driver writes corrupt the
// handle (the MC code indexes inflight_len/inflight_present at their MC offsets).
typedef struct mc_array_u64_8 { uint64_t elems[8]; } mc_array_u64_8;
typedef struct mc_array_u32_8 { uint32_t elems[8]; } mc_array_u32_8;
typedef struct mc_array_bool_8 { uint8_t elems[8]; } mc_array_bool_8;
typedef struct Virtq {
    DescTable *desc; VringAvail *avail; VringUsed *used;
    uint16_t size; uint16_t free_head; uint16_t num_free; uint16_t last_used;
    mc_array_u64_8 inflight_addr;
    mc_array_u32_8 inflight_len;
    mc_array_bool_8 inflight_present;
} Virtq;
typedef struct CpuBuffer { uintptr_t dev_addr; uintptr_t cpu_addr; uintptr_t len; } CpuBuffer;
typedef struct DeviceBuffer { uintptr_t dev_addr; uintptr_t len; } DeviceBuffer;
typedef struct VirtioMmio VirtioMmio;

// The typed kernel entry (tests/qemu/net/http_get_demo.mc).
uint32_t http_get_drive(volatile VirtioMmio *regs, Virtq *rxq, Virtq *txq,
                        uint16_t dst_port, uintptr_t rxbuf, uintptr_t rxmax);
uintptr_t http_resp_len(void);
uint8_t http_resp_byte(uintptr_t i);
static uint8_t framebuf[2048];

// The HTTP server port (must match tools/net/http-get-test.sh).
#define HTTP_PORT 8080

// ----- std/dma platform primitives: a bump allocator over one DMA pool -----
// TCP drives many RX refills + TX segments, none freed (bump pool), so size it
// generously. Exhaustion halts rather than overruns.
static uint8_t g_dma_pool[8u << 20] __attribute__((aligned(16))); // 8 MiB
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

static volatile VirtioMmio *find_net_device(void) {
    for (int i = 0; i < VIRTIO_MMIO_COUNT; ++i) {
        volatile uint32_t *slot = (volatile uint32_t *)(VIRTIO_MMIO_BASE + (uintptr_t)i * VIRTIO_MMIO_STRIDE);
        if (slot[0] == 0x74726976u && slot[2] == 1u) return (volatile VirtioMmio *)slot;
    }
    return 0;
}

// Print the captured response, escaping CR/LF so the UART transcript stays on lines.
static void dump_response(void) {
    uintptr_t n = http_resp_len();
    puts_("RESP-LEN="); puthex(n); putc_('\n');
    puts_("RESP-BEGIN\n");
    for (uintptr_t i = 0; i < n; ++i) {
        uint8_t b = http_resp_byte(i);
        putc_((char)b); // raw bytes (the response is text; CR/LF render as newlines)
    }
    puts_("\nRESP-END\n");
}

__attribute__((used)) void test_main(void) {
    volatile VirtioMmio *regs = find_net_device();
    if (!regs) { puts_("NODEV\n"); goto done; }

    static Virtq rxq, txq; // BSS-zeroed
    rxq.desc = &g_rx_desc; rxq.avail = &g_rx_avail; rxq.used = &g_rx_used;
    txq.desc = &g_tx_desc; txq.avail = &g_tx_avail; txq.used = &g_tx_used;

    puts_("http-get booting\n");
    uint32_t st = http_get_drive(regs, &rxq, &txq, HTTP_PORT,
                                 (uintptr_t)framebuf, sizeof(framebuf));
    puts_("DRIVE-STATUS="); puthex(st); putc_('\n');
    switch (st) {
        case 0: puts_("NIC-OR-ARP-FAILED\n"); break;
        case 1: puts_("NO-SYN-ACK\n"); break;
        case 2: puts_("HANDSHAKE-OK-GET-TX-FAILED\n"); break;
        case 3: puts_("HANDSHAKE+GET-OK-NO-RESPONSE\n"); break;
        case 4: puts_("HANDSHAKE+GET+RESPONSE-OK\n"); break;
        default: puts_("UNKNOWN\n"); break;
    }
    if (st == 4) {
        dump_response();
        puts_("HTTP-GET-OK\n");
    }

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
