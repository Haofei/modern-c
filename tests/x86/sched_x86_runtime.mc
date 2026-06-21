// tests/x86/sched_x86_runtime — the x86-64 `kmain` reached from boot.S in 64-bit long mode, in
// PURE MC.
//
// The MC replacement for kernel/arch/x86_64/kmain_runtime.c. boot.S (kept: the genuine 32-bit
// multiboot header + protected-mode->long-mode trampoline MC cannot target) reaches 64-bit long
// mode with the low 1 GiB identity-mapped, running at 1 MiB, and `call kmain`s into here. We:
//
//   1. bring up COM1 (kernel/arch/x86_64/port_io — pure-MC outb/inb);
//   2. run the cooperative round-robin scheduler demo (tests/x86/sched_x86_demo — three threads
//      on private stacks switched via the real pure-MC mc_switch_context / mc_thread_init in
//      kernel/arch/x86_64/context_runtime.mc), which returns 1 iff it produced "ABCABCABC";
//   3. report PASS/FAIL over COM1 and exit QEMU via the isa-debug-exit device.
//
// Output is observable with `-nographic`/`-serial`, so the harness greps for X86-OK. The old
// kmain_runtime.c is deleted; the cooperative scheduler now boots end-to-end on a pure-MC kmain
// + pure-MC context switch.

import "kernel/arch/x86_64/port_io.mc";

const QEMU_EXIT_PORT: u16 = 0xF4;

// The cooperative scheduler demo (tests/x86/sched_x86_demo.mc): runs three threads round-robin
// via the real mc_switch_context and returns 1 iff the output was exactly "ABCABCABC".
extern fn sched_x86_run() -> u32;

// isa-debug-exit device (iobase 0xF4): writing V exits QEMU with status (V<<1)|1.
fn qemu_exit(code: u8) -> void {
    outb(QEMU_EXIT_PORT, code);
}

#[noinline]
fn halt_forever() -> void {
    while true {
        #[unsafe_contract(precise_asm)] {
            unsafe {
                asm precise volatile {
                    "hlt"
                    clobber("memory")
                }
            }
        }
    }
}

export fn kmain() -> void {
    serial_init();
    put_str("x86-64 long mode: boot OK\n");

    let r: u32 = sched_x86_run();
    if r == 1 {
        put_str("X86-OK\n");
        qemu_exit(0);
    } else {
        put_str("X86-FAIL\n");
        qemu_exit(1);
    }
    halt_forever();
}
