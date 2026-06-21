// S-mode/OpenSBI port of kernel/drivers/virtio/net_runtime.c: revalidate the
// EXISTING MC virtio-net RX/TX driver + net stack (kernel/main.mc's kernel_main)
// under REAL OpenSBI firmware in S-mode, instead of the M-mode `-bios none` path.
//
// The ONLY differences vs net_runtime.c are the boot seam: OpenSBI enters in
// S-mode at 0x80200000 with a0=hartid/a1=dtb, so _start preserves a0/a1 and
// calls s_entry(hartid, dtb); console output goes through the SBI legacy putchar
// ecall and halt through the SBI shutdown ecall (instead of the direct
// 0x10000000 UART + SiFive FINISHER from platform.h). Crucially, the time source
// is the architectural `rdtime` CSR instead of the CLINT mtime MMIO that
// platform.h reads — see below. Everything else — the virtio-mmio probe (magic
// 0x74726976 + device_id==1 for net), the bump DMA pool, the RX/TX virtqueue
// memory, and the call into the MC driver (kernel_main) — is IDENTICAL.
//
// satp is left 0 (Bare mode = flat physical). OpenSBI has programmed PMP so
// S-mode can touch RAM + MMIO, so the flat-physical driver and virtio DMA work
// unchanged from the M-mode path.
//
// NOTE: this runtime deliberately does NOT include platform.h. platform.h would
// pull in the direct 16550 UART, the SiFive FINISHER halt, and (fatally) the
// CLINT mtime MMIO read @ 0x0200_BFF8. Under OpenSBI the CLINT/ACLINT mtime
// region is NOT PMP-mapped into S-mode (OpenSBI owns the timer), so a direct
// CLINT load faults and resets the hart. We provide our own SBI console + halt
// and the freestanding mem ops here, and read time via the `rdtime` CSR.
#include <stdint.h>
#include <stddef.h>

#include "platform_virtio.h" // vring + buffer structs, mc_dma_clean/invalidate

// Freestanding libc primitives the compiler emits for struct copies/zeroing.
// (platform.h normally supplies these; we are not including it.)
static void *memset(void *d, int c, size_t n) {
    uint8_t *p = (uint8_t *)d;
    for (size_t i = 0; i < n; ++i) p[i] = (uint8_t)c;
    return d;
}
static void *memcpy(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d; const uint8_t *sp = (const uint8_t *)s;
    for (size_t i = 0; i < n; ++i) dp[i] = sp[i];
    return d;
}

// --- SBI console + shutdown (mirrors blk_smode_runtime.c) -----------------
// One structured SBI ecall: extension id in a7, function id in a6, two args.
static long sbi_ecall(long ext, long fid, long arg0, long arg1) {
    register long a0 __asm__("a0") = arg0;
    register long a1 __asm__("a1") = arg1;
    register long a6 __asm__("a6") = fid;
    register long a7 __asm__("a7") = ext;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a6), "r"(a7) : "memory");
    return a0;
}
// Legacy SBI: console putchar = EID 1, shutdown = EID 8 (fid unused for legacy).
static void sbi_putchar(char c) { sbi_ecall(1, 0, (unsigned char)c, 0); }
static void puts_(const char *s) { for (; *s; ++s) sbi_putchar(*s); }
static void putc_(char c) { sbi_putchar(c); }
static void puthex(uint32_t v) {
    puts_("0x");
    for (int i = 28; i >= 0; i -= 4) sbi_putchar("0123456789abcdef"[(v >> i) & 0xf]);
}
static void sbi_shutdown(void) { sbi_ecall(8, 0, 0, 0); }
static void mc_halt(void) { sbi_shutdown(); for (;;) {} }

// std/time externs the MC net driver needs (TX/RX timeouts). The M-mode runtime
// (via platform.h) reads the CLINT mtime MMIO @ 0x0200_BFF8 directly, but under
// OpenSBI that ACLINT mtime region is NOT mapped into S-mode by PMP (OpenSBI
// owns the timer and exposes it to S-mode via the `time` CSR / SBI timer), so a
// direct CLINT MMIO load faults and resets the hart. The architectural S-mode
// time source is the `time` CSR (rdtime), which OpenSBI keeps in sync with the
// 10 MHz QEMU virt mtimer — same frequency as MC_CLINT_MTIME, so mc_udelay's
// `* 10` scaling is unchanged.
uint64_t mc_read_ticks(void) {
    uint64_t t;
    __asm__ volatile("rdtime %0" : "=r"(t));
    return t;
}
void mc_udelay(uint32_t us) {
    uint64_t t = mc_read_ticks() + (uint64_t)us * 10u;
    while (mc_read_ticks() < t) {}
}

// The typed kernel entry (kernel/main.mc).
uint32_t kernel_main(volatile VirtioMmio *regs, Virtq *rxq, Virtq *txq);

// ----- std/dma platform primitives: a bump allocator over one DMA pool -----
// Multiple buffers can be outstanding (RX ring + TX frames). A bump allocator
// never aliases live buffers; `free` is a no-op (the pool is one-shot for this
// smoke test). Exhaustion halts rather than overruns. IDENTICAL to net_runtime.c.
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
// (mc_dma_clean_for_device_base / mc_dma_invalidate_for_cpu_base come from platform_virtio.h)

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

// The platform provides device discovery (the device-id probe scan finds the net
// device among the 8 virtio-mmio slots; correct on QEMU virt). IDENTICAL to the
// M-mode runtime.
static volatile VirtioMmio *find_net_device(void) {
    for (int i = 0; i < VIRTIO_MMIO_COUNT; ++i) {
        volatile uint32_t *slot = (volatile uint32_t *)(VIRTIO_MMIO_BASE + (uintptr_t)i * VIRTIO_MMIO_STRIDE);
        if (slot[0] == 0x74726976u && slot[2] == 1u) return (volatile VirtioMmio *)slot; // device_id 1 = net
    }
    return 0;
}

// OpenSBI enters in S-mode with a0=hartid, a1=dtb. dtb is available for optional
// FDT discovery, but the device-id probe scan is what actually finds the net
// device among the 8 virtio-mmio slots, so we keep the hardcoded base + probe.
__attribute__((used)) void s_entry(uint64_t hartid, uint64_t dtb) {
    (void)hartid; (void)dtb;
    puts_("net: S-mode under OpenSBI\n");

    volatile VirtioMmio *regs = find_net_device();
    if (!regs) { puts_("NODEV\n"); goto done; }
    puts_("net: device found\n");

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

// OpenSBI enters here in S-mode with a0=hartid, a1=dtb. Set the stack but DO NOT
// clobber a0/a1 before the call, so s_entry receives them as its first two args.
__attribute__((naked, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call s_entry\n"
        "1: j 1b\n");
}
