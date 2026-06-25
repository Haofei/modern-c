// VisionFive 2 readiness surrogate — PURE MC, booted by OpenSBI in S-mode.
//
// QEMU `virt` is not VisionFive 2 hardware. This fixture validates the current
// board profile's FDT-driven boot contract against the deterministic QEMU DTB so
// changes to BootInfo/device discovery cannot silently break the real-board
// adapter while hardware is unavailable.

import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_console.mc";
import "kernel/platform/starfive_visionfive2/readiness.mc";
import "std/addr.mc";

export fn s_entry(hartid: u64, dtb: u64) -> void {
    sbi_puts("kernel up in S-mode under OpenSBI (VisionFive 2 readiness surrogate)\n");

    let r: VisionFive2Readiness = visionfive2_qemu_surrogate_readiness(pa(dtb as usize), hartid);
    sbi_puts("vf2_boot_cpu=");
    put_dec(r.boot_cpu_id);
    sbi_putchar(10);
    sbi_puts("vf2_fdt=");
    put_hex(r.fdt_pointer);
    sbi_putchar(10);
    sbi_puts("vf2_console=");
    put_hex(r.console_base);
    sbi_putchar(10);
    sbi_puts("vf2_plic=");
    put_hex(r.plic_base);
    sbi_putchar(10);
    sbi_puts("vf2_virtio_mmio_count=");
    put_dec(r.virtio_mmio_count as u64);
    sbi_putchar(10);

    if r.ready {
        sbi_puts("VF2-QEMU-SURROGATE-OK\n");
    } else {
        sbi_puts("VF2-QEMU-SURROGATE-BAD\n");
    }

    sbi_shutdown();
    while true {}
}

#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
