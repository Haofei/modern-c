// Phase R5b / §3.1 BootInfo — in PURE MC (no C). Booted by REAL OpenSBI at
// 0x80200000 in S-mode, this flat kernel PRESERVES OpenSBI's a0/a1 (hartid, dtb
// physaddr) through a `#[naked]` `_start` into `s_entry`, then asks the
// architecture-neutral BootInfo contract (kernel/core/bootinfo.mc) to normalize
// the firmware device tree into one structure, prints a structured boot summary,
// and emits the BOOTINFO-OK/BAD verdict. The boot seam, SBI calls, and number
// formatting are the shared MC modules (sbi.mc / sbi_console.mc). ZERO C.

import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_console.mc";
import "kernel/core/bootinfo.mc";
import "std/addr.mc";

export fn s_entry(hartid: u64, dtb: u64) -> void {
    sbi_puts("kernel up in S-mode under OpenSBI (BootInfo normalization)\n");

    let blob: PAddr = pa(dtb as usize);
    let cpu: u64 = bootinfo_cpu_pa(blob, hartid);
    let fdt: u64 = bootinfo_fdt_pa(blob, hartid);
    let mbase: u64 = bootinfo_mem_base_pa(blob, hartid);
    let msize: u64 = bootinfo_mem_size_pa(blob, hartid);
    let console: u64 = bootinfo_console_pa(blob, hartid);
    let plic: u64 = bootinfo_plic_pa(blob, hartid);
    let vfirst: u64 = bootinfo_virtio_first_pa(blob, hartid);
    let vcount: u32 = bootinfo_virtio_count_pa(blob, hartid);
    let found: bool = bootinfo_mem_found_pa(blob, hartid);

    sbi_puts("BootInfo:\n");
    sbi_puts("  boot_cpu="); put_dec(cpu); sbi_putchar(10);
    sbi_puts("  fdt="); put_hex(fdt); sbi_putchar(10);
    sbi_puts("  mem=["); put_hex(mbase); sbi_puts(",+");
    put_hex(msize); sbi_puts(")\n");
    sbi_puts("  console="); put_hex(console); sbi_putchar(10);
    sbi_puts("  plic="); put_hex(plic); sbi_putchar(10);
    sbi_puts("  virtio_mmio="); put_hex(vfirst);
    sbi_puts(" x"); put_dec(vcount as u64); sbi_putchar(10);

    if found && console != 0 && plic != 0 && vcount > 0 {
        sbi_puts("BOOTINFO-OK\n");
    } else {
        sbi_puts("BOOTINFO-BAD\n");
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
