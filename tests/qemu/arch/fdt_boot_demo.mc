// Real boot path + FDT /memory discovery — in PURE MC (no C). Booted by REAL
// OpenSBI at 0x80200000 in S-mode, this flat kernel PRESERVES OpenSBI's a0/a1
// (hartid, dtb physaddr) through a `#[naked]` `_start` into `s_entry`, then asks
// kernel/core/fdt.mc to walk the device tree's /memory node and reports the
// discovered RAM base/size over the SBI console. The boot seam, SBI calls, and
// number formatting are the shared MC modules (sbi.mc / sbi_console.mc); the FDT
// parse is kernel/core/fdt.mc. The DTB blob length is taken from the FDT header's
// totalsize field inside the fdt.mc entry points.
//
// This is the M1 "RISC-V S-mode hello" acceptance + the Phase R5 FDT-discovery
// seed, now with ZERO C: `_start` is `#[naked]` MC and every accessor is MC.

import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_console.mc";
import "kernel/core/fdt.mc";
import "std/addr.mc";

export fn s_entry(hartid: u64, dtb: u64) -> void {
    sbi_puts("kernel up in S-mode under OpenSBI\n");

    sbi_puts("hart=");
    put_dec(hartid);
    sbi_putchar(10); // '\n'

    sbi_puts("dtb=");
    put_hex(dtb);
    sbi_putchar(10);

    let blob: PAddr = pa(dtb as usize);
    let base: u64 = fdt_boot_base_pa(blob);
    let size: u64 = fdt_boot_size_pa(blob);
    let mem_ok: bool = fdt_boot_ok_pa(blob);

    sbi_puts("mem_base=");
    put_hex(base);
    sbi_putchar(10);
    sbi_puts("mem_size=");
    put_hex(size);
    sbi_putchar(10);

    if mem_ok && base != 0 && size != 0 {
        sbi_puts("FDT-BOOT-OK\n");
    } else {
        sbi_puts("FDT-BOOT-BAD\n");
    }

    sbi_shutdown();
    while true {}
}

// OpenSBI enters in S-mode at 0x80200000 with a0=hartid, a1=dtb. Set the stack
// but DO NOT clobber a0/a1 before the call, so they flow into s_entry as its
// first two arguments. `#[section(".text.boot")]` pins `_start` to 0x80200000
// (sbi.ld KEEPs .text.boot first), where OpenSBI jumps.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
