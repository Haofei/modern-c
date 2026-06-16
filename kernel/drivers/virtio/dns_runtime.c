// DNS-resolve + HTTP-GET runtime: platform glue (virtio-mmio discovery, a bump DMA
// allocator, the vring memory) that drives the MC resolver+client demo
// (tests/qemu/net/dns_http_demo) under QEMU user networking. It pushes a hostname into
// the kernel, calls dns_http_drive (real DNS A-query over UDP -> parse -> TCP GET to the
// resolved IP), and reports the resolved IP + response + DNS-HTTP-OK over the QEMU
// `virt` 16550 UART. Modeled on http_get_runtime.c.
//
// Compile-time parameters (the test scripts override via -D):
//   DNS_SERVER_IP : the DNS server to query, as a host-order u32 (big-endian dotted).
//   HTTP_PORT     : the TCP port to GET after resolving.
//   DNS_HOSTNAME  : the hostname string to resolve.
#include <stdint.h>
#include <stddef.h>

#ifndef DNS_SERVER_IP
#define DNS_SERVER_IP 0x0A000202u /* 10.0.2.2 (slirp gateway -> host loopback) */
#endif
#ifndef HTTP_PORT
#define HTTP_PORT 8080
#endif
#ifndef DNS_HOSTNAME
#define DNS_HOSTNAME "host.test"
#endif

#define CLINT_MTIME 0x0200BFF8UL
uint64_t mc_read_ticks(void) { return *(volatile uint64_t *)CLINT_MTIME; }
void mc_udelay(uint32_t us) {
    uint64_t target = *(volatile uint64_t *)CLINT_MTIME + (uint64_t)us * 10u;
    while (*(volatile uint64_t *)CLINT_MTIME < target) { }
}

// ----- virtqueue structs (A2: single source of truth) -----
// GENERATED from std/virtqueue.mc by `mcc emit-c-struct` (tools/qemu/kernel-boot-lib.sh) — the MC
// struct is the only declaration, so this runtime can never drift from MC's `Virtq` layout. The
// generated header also carries the A1 sizeof/offsetof asserts. No hand-written mirror remains here.
#include "virtq_structs.h"
typedef struct CpuBuffer { uintptr_t dev_addr; uintptr_t cpu_addr; uintptr_t len; } CpuBuffer;
typedef struct DeviceBuffer { uintptr_t dev_addr; uintptr_t len; } DeviceBuffer;
typedef struct VirtioMmio VirtioMmio;

// The typed kernel entry points (tests/qemu/net/dns_http_demo.mc).
uint32_t dns_http_drive(volatile VirtioMmio *regs, Virtq *rxq, Virtq *txq,
                        uint32_t dns_ip, uint16_t http_port, uintptr_t rxbuf, uintptr_t rxmax);
uint32_t dns_resolved_ip(void);
uintptr_t http_resp_len(void);
uint8_t http_resp_byte(uintptr_t i);
void dns_host_reset(void);
void dns_host_push(uint8_t c);
void dns_req_reset(void);
void dns_req_push(uint8_t c);
static uint8_t framebuf[2048];

// ----- std/dma platform primitives: a bump allocator over one DMA pool -----
static uint8_t g_dma_pool[8u << 20] __attribute__((aligned(16))); // 8 MiB
static uintptr_t g_dma_off = 0;
uintptr_t mc_dma_alloc_base(uintptr_t len) {
    uintptr_t a = (len + 15u) & ~(uintptr_t)15u;
    if (g_dma_off + a > sizeof(g_dma_pool)) {
        for (;;) { }
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
// Print a host-order IPv4 u32 as dotted-quad.
static void put_ip(uint32_t ip) {
    for (int s = 24; s >= 0; s -= 8) {
        uint32_t o = (ip >> s) & 0xff;
        char tmp[3]; int n = 0;
        if (o == 0) { putc_('0'); }
        else { while (o) { tmp[n++] = (char)('0' + (o % 10)); o /= 10; } while (n) putc_(tmp[--n]); }
        if (s) putc_('.');
    }
}

#define FINISHER ((volatile uint32_t *)0x00100000UL)
#define VIRTIO_MMIO_BASE 0x10001000UL
#define VIRTIO_MMIO_STRIDE 0x1000UL
#define VIRTIO_MMIO_COUNT 8

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

static void dump_response(void) {
    uintptr_t n = http_resp_len();
    puts_("RESP-LEN="); puthex(n); putc_('\n');
    puts_("RESP-BEGIN\n");
    for (uintptr_t i = 0; i < n; ++i) putc_((char)http_resp_byte(i));
    puts_("\nRESP-END\n");
}

#define MC_XSTR(x) #x
#define MC_STR(x) MC_XSTR(x)

__attribute__((used)) void test_main(void) {
    volatile VirtioMmio *regs = find_net_device();
    if (!regs) { puts_("NODEV\n"); goto done; }

    static Virtq rxq, txq;
    rxq.desc = &g_rx_desc; rxq.avail = &g_rx_avail; rxq.used = &g_rx_used;
    txq.desc = &g_tx_desc; txq.avail = &g_tx_avail; txq.used = &g_tx_used;

    // Push the hostname to resolve into the kernel.
    const char *host = DNS_HOSTNAME;
    dns_host_reset();
    puts_("dns-http booting; resolving ");
    for (const char *p = host; *p; ++p) { putc_(*p); dns_host_push((uint8_t)*p); }
    puts_(" via DNS server ");
    put_ip((uint32_t)DNS_SERVER_IP);
    puts_(" port "); puthex(HTTP_PORT); putc_('\n');

    // Optional: override the HTTP request bytes (e.g. the google.com fetch supplies a
    // proper Host header + Connection: close). Without -DHTTP_REQUEST the kernel uses
    // its built-in "GET / HTTP/1.0 ... Host: 10.0.2.2" default.
#ifdef HTTP_REQUEST
    {
        const char *req = HTTP_REQUEST;
        dns_req_reset();
        for (const char *p = req; *p; ++p) dns_req_push((uint8_t)*p);
    }
#endif

    uint32_t st = dns_http_drive(regs, &rxq, &txq, (uint32_t)DNS_SERVER_IP, HTTP_PORT,
                                 (uintptr_t)framebuf, sizeof(framebuf));
    puts_("DRIVE-STATUS="); puthex(st); putc_('\n');

    uint32_t ip = dns_resolved_ip();
    if (ip != 0) {
        puts_("RESOLVED-IP="); puthex(ip); puts_(" ("); put_ip(ip); puts_(")\n");
    }

    switch (st) {
        case 0: puts_("NIC-OR-ARP-FAILED\n"); break;
        case 5: puts_("DNS-QUERY-TX-FAILED\n"); break;
        case 6: puts_("DNS-NO-RESPONSE\n"); break;
        case 1: puts_("NO-SYN-ACK\n"); break;
        case 2: puts_("HANDSHAKE-OK-GET-TX-FAILED\n"); break;
        case 3: puts_("HANDSHAKE+GET-OK-NO-RESPONSE\n"); break;
        case 4: puts_("HANDSHAKE+GET+RESPONSE-OK\n"); break;
        default: puts_("UNKNOWN\n"); break;
    }
    if (st == 4) {
        dump_response();
        puts_("DNS-HTTP-OK\n");
    }

done:
    *FINISHER = 0x5555;
    for (;;) { }
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
