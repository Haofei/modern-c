// Phase R5 device discovery — in PURE MC (no C). Booted by REAL OpenSBI at
// 0x80200000 in S-mode, this flat kernel PRESERVES OpenSBI's a0/a1 (hartid, dtb
// physaddr) through a `#[naked]` `_start` into `s_entry`, then asks
// kernel/core/fdt.mc to walk the device tree by `compatible` string for the
// UART, the PLIC, and the virtio-mmio devices — decoding each `reg` with its
// parent node's #address-cells/#size-cells — and reports their bases + the
// virtio-mmio count over the SBI console. The boot seam, SBI calls, and number
// formatting are the shared MC modules (sbi.mc / sbi_console.mc). ZERO C.

import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_console.mc";
import "kernel/core/fdt.mc";
import "std/addr.mc";

// Confirmed against the real QEMU virt DTB (-machine virt -m 256M, dumpdtb):
// 8 virtio-mmio nodes at 0x10001000..0x10008000 (stride 0x1000).
const VIRTIO_MMIO_EXPECTED_COUNT: u32 = 8;

export fn s_entry(hartid: u64, dtb: u64) -> void {
    sbi_puts("kernel up in S-mode under OpenSBI (device discovery)\n");

    sbi_puts("hart=");
    put_dec(hartid);
    sbi_putchar(10); // '\n'

    sbi_puts("dtb=");
    put_hex(dtb);
    sbi_putchar(10);

    let blob: PAddr = pa(dtb as usize);
    let uart: u64 = fdt_uart_base_pa(blob);
    let plic: u64 = fdt_plic_base_pa(blob);
    let vfirst: u64 = fdt_virtio_first_base_pa(blob);
    let vcount: u32 = fdt_virtio_count_pa(blob);

    sbi_puts("uart=");
    put_hex(uart);
    sbi_putchar(10);
    sbi_puts("plic=");
    put_hex(plic);
    sbi_putchar(10);
    sbi_puts("virtio_mmio_first=");
    put_hex(vfirst);
    sbi_putchar(10);
    sbi_puts("virtio_mmio_count=");
    put_dec(vcount as u64);
    sbi_putchar(10);

    if uart != 0 && plic != 0 && vfirst != 0 && vcount == VIRTIO_MMIO_EXPECTED_COUNT {
        sbi_puts("FDT-DEV-OK\n");
    } else {
        sbi_puts("FDT-DEV-BAD\n");
    }

    sbi_shutdown();
    while true {}
}

// OpenSBI enters in S-mode at 0x80200000 with a0=hartid, a1=dtb. Set the stack
// but DO NOT clobber a0/a1 before the call. `#[section(".text.boot")]` pins
// `_start` to 0x80200000, where OpenSBI jumps.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
