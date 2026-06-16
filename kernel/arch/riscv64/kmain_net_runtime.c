// Merged bring-up runtime for the integrated kernel + network image. Combines the
// context-switch primitives (for the scheduler) with the virtio-mmio device
// discovery + DMA pool + vring memory (for the NIC). One _start, one test_main:
// discover the NIC, then run kmain_net (core subsystems + a UDP transmit).
#include <stdint.h>

// CLINT time source (std/time externs; needed now that std/virtqueue uses vq_wait_used).
#define CLINT_MTIME 0x0200BFF8UL
uint64_t mc_read_ticks(void) { return *(volatile uint64_t *)CLINT_MTIME; }
void mc_udelay(uint32_t us) { uint64_t t = mc_read_ticks() + (uint64_t)us * 10u; while (mc_read_ticks() < t) {} }
#include <stddef.h>

#define UART_THR ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
void putc_(char c) { *UART_THR = (uint8_t)c; }
void puts_(const char *s) { while (*s) putc_(*s++); }
void mc_halt(void) { *FINISHER = 0x5555; for (;;) {} }

// ----- context switch (scheduler) -----
typedef struct {
    uint64_t ra, sp, s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
} Context;
__attribute__((naked)) void mc_switch_context(Context *old, Context *next) {
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
__attribute__((naked)) static void thread_trampoline(void) {
    __asm__ volatile("csrsi mstatus, 8\n" "jr s0\n");
}
void mc_thread_init(Context *ctx, uintptr_t stack_top, void (*entry)(void)) {
    uint64_t *slots = (uint64_t *)ctx;
    for (int i = 0; i < 14; i++) slots[i] = 0;
    ctx->ra = (uint64_t)(uintptr_t)&thread_trampoline;
    ctx->s0 = (uint64_t)(uintptr_t)entry;
    ctx->sp = (uint64_t)stack_top;
}
// Referenced by process.mc's proc_yield_vm (unused here — kmain uses proc_yield).
void mc_switch_context_vm(Context *old, Context *next, uint64_t satp) { (void)old; (void)next; (void)satp; }

// ----- virtqueue + DMA (NIC) -----
// A2 (single source of truth): the virtqueue structs are GENERATED from std/virtqueue.mc by
// `mcc emit-c-struct` (tools/qemu/kernel-boot-lib.sh) — the MC struct is the only declaration, so
// this runtime can never drift from MC's `Virtq` layout (the missing-field BSS-corruption / boot-
// hang class is structurally impossible). The generated header also carries the A1 sizeof/offsetof
// asserts. No hand-written mirror remains here.
#include "virtq_structs.h"
typedef struct CpuBuffer { uintptr_t dev_addr; uintptr_t cpu_addr; uintptr_t len; } CpuBuffer;
typedef struct DeviceBuffer { uintptr_t dev_addr; uintptr_t len; } DeviceBuffer;
typedef struct VirtioMmio VirtioMmio;

static uint8_t g_dma_pool[2048] __attribute__((aligned(16)));
static int g_dma_in_use = 0;
uintptr_t mc_dma_alloc_base(uintptr_t len) {
    if (len > sizeof(g_dma_pool) || g_dma_in_use) { for (;;) {} }
    g_dma_in_use = 1;
    for (uintptr_t i = 0; i < len; ++i) g_dma_pool[i] = 0;
    return (uintptr_t)g_dma_pool;
}
void mc_dma_free_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; g_dma_in_use = 0; }
void mc_dma_clean_for_device_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; }
uintptr_t mc_dma_invalidate_for_cpu_base(uintptr_t dev_addr, uintptr_t len) { (void)len; return dev_addr; }

#define VIRTIO_MMIO_BASE 0x10001000UL
#define VIRTIO_MMIO_STRIDE 0x1000UL
#define VIRTIO_MMIO_COUNT 8
static DescTable  g_desc  __attribute__((aligned(16)));
static VringAvail g_avail __attribute__((aligned(2)));
static VringUsed  g_used  __attribute__((aligned(4)));

static volatile VirtioMmio *find_net_device(void) {
    for (int i = 0; i < VIRTIO_MMIO_COUNT; ++i) {
        volatile uint32_t *slot = (volatile uint32_t *)(VIRTIO_MMIO_BASE + (uintptr_t)i * VIRTIO_MMIO_STRIDE);
        if (slot[0] == 0x74726976u && slot[2] == 1u) return (volatile VirtioMmio *)slot;
    }
    return 0;
}

uint32_t kmain_net(uintptr_t region, uintptr_t len, volatile VirtioMmio *regs, Virtq *txq);

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];

__attribute__((used)) void test_main(void) {
    puts_("kmain-net boot (integrated kernel + network)\n");
    volatile VirtioMmio *regs = find_net_device();
    if (!regs) { puts_("NODEV\n"); mc_halt(); }
    static Virtq txq;
    txq.desc = &g_desc; txq.avail = &g_avail; txq.used = &g_used;

    uint32_t stages = kmain_net((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region), regs, &txq);
    puts_("\nstages=0x");
    putc_("0123456789abcdef"[(stages >> 4) & 0xf]);
    putc_("0123456789abcdef"[stages & 0xf]);
    putc_('\n');
    if (stages == 0x3F) puts_("KERNEL-NET-OK\n"); // core subsystems + networking
    else puts_("KERNEL-NET-INCOMPLETE\n");
    mc_halt();
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
