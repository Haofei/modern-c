// S-mode/OpenSBI port of blk_runtime.c: revalidate the EXISTING MC virtio-blk
// driver (tests/qemu/fs/blk_demo.mc) under REAL OpenSBI firmware in S-mode,
// instead of the M-mode `-bios none` path.
//
// The ONLY differences vs blk_runtime.c are the boot seam: OpenSBI enters in
// S-mode at 0x80200000 with a0=hartid/a1=dtb, so _start preserves a0/a1 and
// calls s_entry(hartid, dtb); console output goes through the SBI legacy
// putchar ecall and halt through the SBI shutdown ecall (instead of the direct
// 0x10000000 UART + SiFive FINISHER). Everything else — the virtio-mmio probe
// (magic 0x74726976 + device_id==2), the DMA bump pool, the virtqueue memory,
// and the call into the MC driver (blk_demo_run) — is IDENTICAL.
//
// satp is left 0 (Bare mode = flat physical). OpenSBI has programmed PMP so
// S-mode can touch RAM + MMIO, so the flat-physical driver and virtio DMA work
// unchanged from the M-mode path.
#include <stdint.h>
#include <stddef.h>

#include "platform_virtio.h" // vring + buffer structs, mc_dma_clean/invalidate

// --- SBI console + shutdown (mirrors fdt_boot_runtime.c) ------------------
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
static void sbi_puts(const char *s) { for (; *s; ++s) sbi_putchar(*s); }
static void sbi_shutdown(void) { sbi_ecall(8, 0, 0, 0); }

// std/time externs the MC driver needs. The M-mode runtime reads the CLINT
// mtime MMIO @ 0x0200_BFF8 directly, but under OpenSBI the CLINT/ACLINT mtime
// region is NOT mapped into S-mode by PMP (OpenSBI owns the timer and exposes it
// to S-mode via the `time` CSR / SBI timer), so a direct CLINT MMIO load faults
// and resets the hart. The architectural S-mode time source is the `time` CSR
// (rdtime), which OpenSBI keeps in sync with the 10 MHz QEMU virt mtimer — same
// frequency as MC_CLINT_MTIME, so mc_udelay's `* 10` scaling is unchanged.
uint64_t mc_read_ticks(void) {
    uint64_t t;
    __asm__ volatile("rdtime %0" : "=r"(t));
    return t;
}
void mc_udelay(uint32_t us) {
    uint64_t t = mc_read_ticks() + (uint64_t)us * 10u;
    while (mc_read_ticks() < t) {}
}

uint64_t blk_demo_run(volatile VirtioMmio *regs, Virtq *vq, uint64_t sector);

// std/dma pool: a small bump pool (the blk chain holds three buffers — header/data/
// status — outstanding at once, unlike the net path's one).
static uint8_t g_dma_pool[4096] __attribute__((aligned(16)));
static uintptr_t g_dma_off = 0;
uintptr_t mc_dma_alloc_base(uintptr_t len) {
    uintptr_t a = (g_dma_off + 15) & ~(uintptr_t)15;
    if (a + len > sizeof(g_dma_pool)) for (;;) {}
    g_dma_off = a + len;
    for (uintptr_t i = 0; i < len; ++i) g_dma_pool[a + i] = 0;
    return (uintptr_t)(g_dma_pool + a);
}
void mc_dma_free_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; }

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

// OpenSBI enters in S-mode with a0=hartid, a1=dtb. dtb is available for optional
// FDT discovery, but the device-id probe scan is what actually finds the blk
// device among the 8 virtio-mmio slots, so we keep the hardcoded base + probe
// (correct on QEMU virt).
__attribute__((used)) void s_entry(uint64_t hartid, uint64_t dtb) {
    (void)hartid; (void)dtb;
    sbi_puts("blk: S-mode under OpenSBI\n");

    volatile VirtioMmio *regs = find_blk_device();
    if (!regs) { sbi_puts("NODEV\n"); goto done; }
    sbi_puts("blk: device found\n");

    static Virtq vq;
    vq.desc = &g_desc; vq.avail = &g_avail; vq.used = &g_used;

    uint64_t word = blk_demo_run(regs, &vq, 0);
    if (word == (uint64_t)-1) { sbi_puts("BLK-INIT-FAIL\n"); goto done; }
    if (word == (uint64_t)-2) { sbi_puts("BLK-READ-FAIL\n"); goto done; }

    // `word` is the first little-endian 32-bit word of sector 0.
    sbi_puts("BLK-READ ");
    sbi_putchar((char)(word & 0xFF));
    sbi_putchar((char)((word >> 8) & 0xFF));
    sbi_putchar((char)((word >> 16) & 0xFF));
    sbi_putchar((char)((word >> 24) & 0xFF));
    sbi_puts("\nBLK-OK\n");

done:
    sbi_shutdown();
    for (;;) {}
}

// OpenSBI enters here in S-mode with a0=hartid, a1=dtb. Set the stack but DO NOT
// clobber a0/a1 before the call, so s_entry receives them as its first two args.
__attribute__((naked, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call s_entry\n"
        "1: j 1b\n");
}
