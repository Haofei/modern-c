// tests/arm/boot_arm_runtime — the minimal AArch64 second-architecture bring-up, PURE MC.
//
// The MC replacement for kernel/arch/aarch64/boot_runtime.c. There is NO boot.S: QEMU 'virt'
// -kernel loads this flat image at RAM base 0x40000000 and enters at the load address (EL1, or
// EL2 from which the naked `_start` below drops). It sets SP, prints over the PL011 UART
// (kernel/arch/aarch64/pl011 — pure MC), runs the arch-neutral MC computation (arch_compute),
// and reports ARM64-OK iff it returns the expected value — proving MC code + the arch-isolated
// kernel layout run on a second architecture. This whole boot seam is now MC.

import "tests/qemu/arch/arch_demo.mc";
import "kernel/arch/aarch64/pl011.mc";

export fn cmain() -> void {
    put_str("aarch64 booting\n");
    // sum(0..9)=45; *2+1 = 91
    if arch_compute(10) == 91 {
        put_str("ARM64-OK\n");
    } else {
        put_str("ARM64-BAD\n");
    }
    while true {
        #[unsafe_contract(precise_asm)] {
            unsafe {
                asm precise volatile { "wfe" clobber("memory") }
            }
        }
    }
}

// QEMU 'virt' -kernel enters the flat image at its load address (0x40000000). `#[section]` pins
// `_start` to `.text.boot` (aarch64.ld: leads .text, ENTRY(_start)). Set SP from the linker
// `_stack_top`; if we boot at EL2 drop to EL1 via `eret`; then `bl cmain`. No boot.S.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "ldr x1, =_stack_top\n mov sp, x1\n mrs x0, CurrentEL\n lsr x0, x0, #2\n and x0, x0, #3\n cmp x0, #2\n b.ne 2f\n mov x0, #(1 << 31)\n msr hcr_el2, x0\n mov x0, #0x3c5\n msr spsr_el2, x0\n adr x0, 1f\n msr elr_el2, x0\n isb\n eret\n1:\n ldr x1, =_stack_top\n mov sp, x1\n2:\n bl cmain\n3: wfe\n b 3b"
    }
}
