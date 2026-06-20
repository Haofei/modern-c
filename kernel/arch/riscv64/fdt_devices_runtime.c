// Phase R5 device discovery: boot under OpenSBI (real RISC-V firmware) in S-mode,
// PRESERVE OpenSBI's a0/a1 (hartid, dtb physaddr), and ask kernel/core/fdt.mc to
// walk the device tree by `compatible` string for the UART, the PLIC, and the
// virtio-mmio devices — decoding each `reg` with its parent node's cell counts.
// This is the device-discovery sibling of fdt_boot_runtime.c (which only parses
// /memory); the two share the same minimal structured SBI wrapper + print
// helpers (copied here so the M1 boot file stays untouched).
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

// MC entry points (kernel/core/fdt.mc via the fdt_devices_demo fixture). PAddr
// is an opaque usize-width address class on the MC side; across the C ABI it is
// a plain uint64_t.
uint64_t fdt_dev_uart_base(uint64_t dtb);
uint64_t fdt_dev_plic_base(uint64_t dtb);
uint64_t fdt_dev_virtio_first_base(uint64_t dtb);
uint32_t fdt_dev_virtio_count(uint64_t dtb);

// Confirmed against the real QEMU virt DTB (-machine virt -m 256M, dumpdtb):
// 8 virtio-mmio nodes at 0x10001000..0x10008000 (stride 0x1000).
#define VIRTIO_MMIO_EXPECTED_COUNT 8u

__attribute__((used)) void s_entry(uint64_t hartid, uint64_t dtb) {
    sbi_puts("kernel up in S-mode under OpenSBI (device discovery)\n");

    sbi_puts("hart=");
    sbi_put_u64_dec(hartid);
    sbi_putchar('\n');

    sbi_puts("dtb=");
    sbi_put_hex64(dtb);
    sbi_putchar('\n');

    uint64_t uart = fdt_dev_uart_base(dtb);
    uint64_t plic = fdt_dev_plic_base(dtb);
    uint64_t vfirst = fdt_dev_virtio_first_base(dtb);
    uint32_t vcount = fdt_dev_virtio_count(dtb);

    sbi_puts("uart=");
    sbi_put_hex64(uart);
    sbi_putchar('\n');
    sbi_puts("plic=");
    sbi_put_hex64(plic);
    sbi_putchar('\n');
    sbi_puts("virtio_mmio_first=");
    sbi_put_hex64(vfirst);
    sbi_putchar('\n');
    sbi_puts("virtio_mmio_count=");
    sbi_put_u64_dec((uint64_t)vcount);
    sbi_putchar('\n');

    if (uart != 0 && plic != 0 && vfirst != 0 && vcount == VIRTIO_MMIO_EXPECTED_COUNT) {
        sbi_puts("FDT-DEV-OK\n");
    } else {
        sbi_puts("FDT-DEV-BAD\n");
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
