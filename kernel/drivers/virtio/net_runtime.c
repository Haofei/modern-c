// Bare-metal riscv64 runtime for the kernel virtio-net driver (RX + TX). Does the
// platform's job — virtio-mmio discovery, a bump DMA allocator (multiple
// buffers), the vring memory — and drives the MC net stack through a real ARP
// exchange under QEMU user networking: send an ARP request for the gateway and
// receive slirp's reply on the RX queue. Reports over the QEMU `virt` 16550 UART.
#include <stdint.h>
#include "../../arch/riscv64/platform.h"        // mem/UART/halt/time
#include "../../arch/riscv64/platform_virtio.h" // vring + buffer structs, mc_dma_*

// The typed kernel entry (kernel/main.mc).
uint32_t kernel_main(volatile VirtioMmio *regs, Virtq *rxq, Virtq *txq);

// ----- std/dma platform primitives: a bump allocator over one DMA pool -----
// Multiple buffers can be outstanding (RX ring + TX frames). A bump allocator
// never aliases live buffers; `free` is a no-op (the pool is one-shot for this
// smoke test). Exhaustion halts rather than overruns.
static uint8_t g_dma_pool[65536] __attribute__((aligned(16)));
static uintptr_t g_dma_off = 0;
CpuBuffer mc_dma_alloc(uintptr_t len) {
    uintptr_t a = (len + 15u) & ~(uintptr_t)15u; // 16-byte aligned
    if (g_dma_off + a > sizeof(g_dma_pool)) {
        for (;;) {
        } // pool exhausted
    }
    uint8_t *p = g_dma_pool + g_dma_off;
    g_dma_off += a;
    for (uintptr_t i = 0; i < len; ++i) p[i] = 0;
    CpuBuffer b = { (uintptr_t)p, (uintptr_t)p, len };
    return b;
}
void mc_dma_free(CpuBuffer b) { (void)b; }
// (mc_dma_clean_for_device / mc_dma_invalidate_for_cpu come from platform_virtio.h)

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

    puts_("MC typed kernel booting\n");
    uint32_t rc = kernel_main(regs, &rxq, &txq);
    if (rc != 0) { puts_("KERNEL-FAIL "); puthex(rc); putc_('\n'); goto done; }
    puts_("NET-PING-OK\n");

done:
    mc_halt();
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
