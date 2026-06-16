// AGENT-NET-REAL runtime: platform glue that merges the net-device boot from http_get_runtime.c
// (virtio-mmio discovery, a bump DMA allocator, the vring memory) with the agent-runtime story from
// the agent-net demos. It drives the MC entry tests/qemu/proc/agent_net_real_demo, which spawns a
// sandboxed agent that reaches a live HTTP server ONLY through the broker's REAL tcp_socket transport
// (net_fetch_tcp). The MC code prints the stage markers W/D/B/A over the UART as each broker stage
// passes; this runtime brings up the NIC handle, prints the captured real response body, and prints
// AGENT-NET-REAL-OK when the full brokered-network story passed (stages == 0xF).
#include <stdint.h>
#include <stddef.h>

// std/time platform primitives: monotonic ticks from the CLINT mtime counter (10 MHz on QEMU virt).
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

// The typed kernel entry (tests/qemu/proc/agent_net_real_demo.mc).
uint32_t agent_net_real_main(volatile VirtioMmio *regs, Virtq *rxq, Virtq *txq, uint16_t dst_port);
uintptr_t agent_net_real_resp_len(void);
uint8_t agent_net_real_resp_byte(uintptr_t i);

// The HTTP server port (must match HTTP_PORT in tools/proc/agent-net-real-test.sh).
#define HTTP_PORT 8080

// ----- std/dma platform primitives: a bump allocator over one DMA pool -----
static uint8_t g_dma_pool[8u << 20] __attribute__((aligned(16))); // 8 MiB
static uintptr_t g_dma_off = 0;
uintptr_t mc_dma_alloc_base(uintptr_t len) {
    uintptr_t a = (len + 15u) & ~(uintptr_t)15u; // 16-byte aligned
    if (g_dma_off + a > sizeof(g_dma_pool)) {
        for (;;) { } // pool exhausted
    }
    uint8_t *p = g_dma_pool + g_dma_off;
    g_dma_off += a;
    for (uintptr_t i = 0; i < len; ++i) p[i] = 0;
    return (uintptr_t)p;
}
void mc_dma_free_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; }
void mc_dma_clean_for_device_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; }
uintptr_t mc_dma_invalidate_for_cpu_base(uintptr_t dev_addr, uintptr_t len) { (void)len; return dev_addr; }

// ----- context-switch surface (matches kernel/arch/riscv64/context_runtime.c) -----
// process.mc/agent.mc reference these via proc_spawn_attenuated → proc_spawn (which primes a
// thread context). This image drives the agent INLINE on the boot thread and never switches into
// the spawned context, but the symbols must resolve and the table entry must be validly primed.
// Provided here (not by linking context_runtime.c) so this image stays self-contained — that
// runtime also defines putc_/puts_/_start/test_main, which would collide with ours.
typedef struct {
    uint64_t ra, sp;
    uint64_t s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
} Context;

__attribute__((naked)) void mc_switch_context(Context *old, Context *new) {
    __asm__ volatile(
        "sd ra,  0(a0)\n" "sd sp,  8(a0)\n"
        "sd s0, 16(a0)\n" "sd s1, 24(a0)\n" "sd s2, 32(a0)\n" "sd s3, 40(a0)\n"
        "sd s4, 48(a0)\n" "sd s5, 56(a0)\n" "sd s6, 64(a0)\n" "sd s7, 72(a0)\n"
        "sd s8, 80(a0)\n" "sd s9, 88(a0)\n" "sd s10,96(a0)\n" "sd s11,104(a0)\n"
        "ld ra,  0(a1)\n" "ld sp,  8(a1)\n"
        "ld s0, 16(a1)\n" "ld s1, 24(a1)\n" "ld s2, 32(a1)\n" "ld s3, 40(a1)\n"
        "ld s4, 48(a1)\n" "ld s5, 56(a1)\n" "ld s6, 64(a1)\n" "ld s7, 72(a1)\n"
        "ld s8, 80(a1)\n" "ld s9, 88(a1)\n" "ld s10,96(a1)\n" "ld s11,104(a1)\n"
        "ret\n");
}

__attribute__((naked)) void mc_switch_context_vm(Context *old, Context *next, uint64_t new_satp) {
    __asm__ volatile(
        "sd ra,  0(a0)\n" "sd sp,  8(a0)\n"
        "sd s0, 16(a0)\n" "sd s1, 24(a0)\n" "sd s2, 32(a0)\n" "sd s3, 40(a0)\n"
        "sd s4, 48(a0)\n" "sd s5, 56(a0)\n" "sd s6, 64(a0)\n" "sd s7, 72(a0)\n"
        "sd s8, 80(a0)\n" "sd s9, 88(a0)\n" "sd s10,96(a0)\n" "sd s11,104(a0)\n"
        "csrw satp, a2\n" "sfence.vma\n"
        "ld ra,  0(a1)\n" "ld sp,  8(a1)\n"
        "ld s0, 16(a1)\n" "ld s1, 24(a1)\n" "ld s2, 32(a1)\n" "ld s3, 40(a1)\n"
        "ld s4, 48(a1)\n" "ld s5, 56(a1)\n" "ld s6, 64(a1)\n" "ld s7, 72(a1)\n"
        "ld s8, 80(a1)\n" "ld s9, 88(a1)\n" "ld s10,96(a1)\n" "ld s11,104(a1)\n"
        "ret\n");
}

__attribute__((naked)) static void thread_trampoline(void) {
    __asm__ volatile(
        "csrsi mstatus, 8\n"
        "jr s0\n");
}

void mc_thread_init(Context *ctx, uintptr_t stack_top, void (*entry)(void)) {
    uint64_t *slots = (uint64_t *)ctx;
    for (int i = 0; i < 14; i++) slots[i] = 0;
    ctx->ra = (uint64_t)(uintptr_t)&thread_trampoline;
    ctx->s0 = (uint64_t)(uintptr_t)entry;
    ctx->sp = (uint64_t)stack_top;
}

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

// Print the captured real response body (the broker's first allowed fetch), CR/LF rendered raw.
static void dump_response(void) {
    uintptr_t n = agent_net_real_resp_len();
    puts_("\nRESP-LEN="); puthex(n); putc_('\n');
    puts_("RESP-BEGIN\n");
    for (uintptr_t i = 0; i < n; ++i) putc_((char)agent_net_real_resp_byte(i));
    puts_("\nRESP-END\n");
}

__attribute__((used)) void test_main(void) {
    puts_("\nagent-net-real boot (sandboxed agent making a REAL brokered network call)\n");
    volatile VirtioMmio *regs = find_net_device();
    if (!regs) { puts_("NODEV\n"); goto done; }

    static Virtq rxq, txq; // BSS-zeroed
    rxq.desc = &g_rx_desc; rxq.avail = &g_rx_avail; rxq.used = &g_rx_used;
    txq.desc = &g_tx_desc; txq.avail = &g_tx_avail; txq.used = &g_tx_used;

    // The MC story prints the stage markers W/D/B/A as each broker stage passes.
    uint32_t stages = agent_net_real_main(regs, &rxq, &txq, HTTP_PORT);
    puts_("\nstages=");
    puthex(stages);
    putc_('\n');

    dump_response();

    if (stages == 0xF) puts_("AGENT-NET-REAL-OK\n"); // real web fetch + Denied + Budget + audit
    else puts_("AGENT-NET-REAL-INCOMPLETE\n");

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
