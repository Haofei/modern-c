// Boot under OpenSBI (real RISC-V firmware) in S-mode, and — unlike sbi_boot_runtime.c
// — PRESERVE the boot arguments OpenSBI passes in a0/a1 (hartid, dtb physaddr) and hand
// them to the kernel. The kernel parses the device tree's /memory node (in MC, via
// kernel/core/fdt.mc) and reports the discovered RAM base/size. This is the M1
// "RISC-V S-mode hello" acceptance + the Phase R5 FDT-discovery seed.
//
// SBI is reached through one minimal structured wrapper (sbi_ecall) — the R1 "SBI call
// wrapper" seed — used for both the legacy console and shutdown calls.
#include <stdint.h>
#include <stddef.h>

// One structured SBI ecall: extension id in a7, function id in a6, two args in a0/a1.
// Returns the a0 result (legacy calls ignore a6/return in a0; that's fine here).
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

// MC entry points (kernel/core/fdt.mc via the fdt_boot_demo fixture). PAddr is an opaque
// usize-width address class on the MC side; across the C ABI it is a plain uint64_t.
uint64_t fdt_boot_base(uint64_t dtb);
uint64_t fdt_boot_size(uint64_t dtb);
int      fdt_boot_ok(uint64_t dtb); // bool -> int across the ABI

__attribute__((used)) void s_entry(uint64_t hartid, uint64_t dtb) {
    sbi_puts("kernel up in S-mode under OpenSBI\n");

    sbi_puts("hart=");
    sbi_put_u64_dec(hartid);
    sbi_putchar('\n');

    sbi_puts("dtb=");
    sbi_put_hex64(dtb);
    sbi_putchar('\n');

    uint64_t base = fdt_boot_base(dtb);
    uint64_t size = fdt_boot_size(dtb);
    int ok = fdt_boot_ok(dtb);

    sbi_puts("mem_base=");
    sbi_put_hex64(base);
    sbi_putchar('\n');
    sbi_puts("mem_size=");
    sbi_put_hex64(size);
    sbi_putchar('\n');

    if (ok && base != 0 && size != 0) sbi_puts("FDT-BOOT-OK\n");
    else sbi_puts("FDT-BOOT-BAD\n");

    sbi_shutdown();
    for (;;) {}
}

// OpenSBI enters here in S-mode with a0=hartid, a1=dtb. Set the stack but DO NOT clobber
// a0/a1 before the call, so s_entry receives them as its first two arguments.
__attribute__((naked, section(".text.boot"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call s_entry\n"
        "1: j 1b\n");
}
