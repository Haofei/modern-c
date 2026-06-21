// Phase R5b / §3.1 BootInfo: boot under OpenSBI (real RISC-V firmware) in S-mode,
// PRESERVE OpenSBI's a0/a1 (hartid, dtb physaddr), and ask the architecture-neutral
// BootInfo contract (kernel/core/bootinfo.mc, via the bootinfo_demo fixture) to
// normalize the device tree into one structure. We then print a structured boot
// summary and the BOOTINFO-OK/BAD verdict. This is the §3.1 sibling of
// fdt_devices_runtime.c (which exposed raw FDT finders); here the same firmware
// input flows through the BootInfo seam the rest of the kernel will consume.
//
// The shared minimal SBI wrapper + print helpers are copied here (as in the
// fdt_*_runtime.c siblings) so the M1 boot file stays untouched.
#include <stdint.h>
#include <stddef.h>

// One structured SBI ecall: extension id in a7, function id in a6, two args in
// a0/a1. Returns the a0 result (legacy calls return in a0; that's fine here).
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

static void sbi_put_u64_dec(uint64_t v) {
    char buf[20];
    int i = 0;
    if (v == 0) { sbi_putchar('0'); return; }
    while (v > 0 && i < 20) { buf[i++] = (char)('0' + (v % 10)); v /= 10; }
    while (i > 0) sbi_putchar(buf[--i]);
}

static void sbi_put_hex64(uint64_t v) {
    sbi_puts("0x");
    for (int shift = 60; shift >= 0; shift -= 4) {
        unsigned nib = (unsigned)((v >> shift) & 0xF);
        sbi_putchar((char)(nib < 10 ? ('0' + nib) : ('a' + nib - 10)));
    }
}

// MC entry points (kernel/core/bootinfo.mc via the bootinfo_demo fixture). PAddr
// is an opaque usize-width address class on the MC side; across the C ABI dtb is a
// plain uint64_t, hartid a uint64_t. Scalar accessors keep the C side free of MC
// struct layout.
uint64_t bootinfo_demo_cpu(uint64_t dtb, uint64_t hartid);
uint64_t bootinfo_demo_fdt(uint64_t dtb, uint64_t hartid);
uint64_t bootinfo_demo_mem_base(uint64_t dtb, uint64_t hartid);
uint64_t bootinfo_demo_mem_size(uint64_t dtb, uint64_t hartid);
uint64_t bootinfo_demo_console(uint64_t dtb, uint64_t hartid);
uint64_t bootinfo_demo_plic(uint64_t dtb, uint64_t hartid);
uint64_t bootinfo_demo_virtio_first(uint64_t dtb, uint64_t hartid);
uint32_t bootinfo_demo_virtio_count(uint64_t dtb, uint64_t hartid);
_Bool    bootinfo_demo_mem_found(uint64_t dtb, uint64_t hartid);

__attribute__((used)) void s_entry(uint64_t hartid, uint64_t dtb) {
    sbi_puts("kernel up in S-mode under OpenSBI (BootInfo normalization)\n");

    uint64_t cpu     = bootinfo_demo_cpu(dtb, hartid);
    uint64_t fdt      = bootinfo_demo_fdt(dtb, hartid);
    uint64_t mbase    = bootinfo_demo_mem_base(dtb, hartid);
    uint64_t msize    = bootinfo_demo_mem_size(dtb, hartid);
    uint64_t console  = bootinfo_demo_console(dtb, hartid);
    uint64_t plic     = bootinfo_demo_plic(dtb, hartid);
    uint64_t vfirst   = bootinfo_demo_virtio_first(dtb, hartid);
    uint32_t vcount   = bootinfo_demo_virtio_count(dtb, hartid);
    _Bool    found    = bootinfo_demo_mem_found(dtb, hartid);

    sbi_puts("BootInfo:\n");
    sbi_puts("  boot_cpu="); sbi_put_u64_dec(cpu); sbi_putchar('\n');
    sbi_puts("  fdt="); sbi_put_hex64(fdt); sbi_putchar('\n');
    sbi_puts("  mem=["); sbi_put_hex64(mbase); sbi_puts(",+");
    sbi_put_hex64(msize); sbi_puts(")\n");
    sbi_puts("  console="); sbi_put_hex64(console); sbi_putchar('\n');
    sbi_puts("  plic="); sbi_put_hex64(plic); sbi_putchar('\n');
    sbi_puts("  virtio_mmio="); sbi_put_hex64(vfirst);
    sbi_puts(" x"); sbi_put_u64_dec((uint64_t)vcount); sbi_putchar('\n');

    if (found && console != 0 && plic != 0 && vcount > 0) {
        sbi_puts("BOOTINFO-OK\n");
    } else {
        sbi_puts("BOOTINFO-BAD\n");
    }

    sbi_shutdown();
    for (;;) {}
}

// OpenSBI enters here in S-mode with a0=hartid, a1=dtb. Set the stack but DO NOT
// clobber a0/a1 before the call, so s_entry receives them as its arguments.
__attribute__((naked, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call s_entry\n"
        "1: j 1b\n");
}
