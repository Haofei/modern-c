// Real boot path under OpenSBI — in PURE MC (no C). Booted by REAL OpenSBI at
// 0x80200000 in S-mode, this flat kernel runs an architecture-neutral MC
// computation (arch_compute, tests/qemu/arch/arch_demo.mc) and reports the result
// over the SBI console, then powers off via the SBI shutdown ecall — exactly as on
// real RISC-V hardware (NOT `-bios none`). The boot seam, SBI console, and shutdown
// are the shared MC modules (sbi.mc); `_start` is `#[naked]` MC pinned to the
// OpenSBI entry by `#[section(".text.boot")]`.
//
// This is the all-MC replacement for kernel/arch/riscv64/sbi_boot_runtime.c.

import "kernel/arch/riscv64/sbi.mc";
import "tests/qemu/arch/arch_demo.mc";

export fn s_entry(hartid: u64, dtb: u64) -> void {
    sbi_puts("kernel up in S-mode under OpenSBI\n");
    if arch_compute(10) == 91 {
        sbi_puts("SBI-BOOT-OK\n");
    } else {
        sbi_puts("SBI-BOOT-BAD\n");
    }
    sbi_shutdown();
    while true {}
}

// OpenSBI enters in S-mode at 0x80200000 with a0=hartid, a1=dtb. Set the stack but
// DO NOT clobber a0/a1 before the call, so they flow into s_entry as its first two
// arguments. `#[section(".text.boot")]` pins `_start` to 0x80200000 (sbi.ld KEEPs
// .text.boot first), where OpenSBI jumps.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
