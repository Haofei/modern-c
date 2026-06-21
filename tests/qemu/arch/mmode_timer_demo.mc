// Bare-metal riscv64 M-mode timer kernel — in PURE MC (no C). The M-mode analogue
// of the OpenSBI S-mode proof (tests/qemu/arch/smode_timer_demo.mc): there is NO
// firmware here (QEMU `-bios none` jumps straight to 0x80000000 in M-mode), so the
// kernel owns the machine CSRs (mtvec/mie/mstatus/mepc/mcause/mtval, `mret`), talks
// to the CLINT directly for the timer (mtime/mtimecmp MMIO — reachable in M-mode,
// unlike under OpenSBI), and prints over the bare 16550 UART (no SBI ecall).
//
// The typed kernel (kernel/arch/riscv64/trap.mc) installs the naked M-mode trap
// vector below through the hart typestate, enables M-timer interrupts, and counts
// CLINT timer ticks; an unexpected trap (here a deliberate M-mode `ecall`) fails
// closed through kernel/core/panic.mc with diagnostics rather than silently
// `mret`-ing. The boot seam — naked `_start` in `.text.start` + the naked trap
// vector — is the reusable M-mode template the rest of the sweep copies.

import "kernel/arch/riscv64/trap.mc";
import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

// SiFive test finisher: writing this code powers the machine off / ends the run.
// (The platform primitives mc_halt/mc_read_ticks/mc_udelay live in the separate
// compilation unit mmode_platform.mc — they DEFINE symbols that panic.mc/time.mc
// declare `extern fn`, so they cannot share this module's flattened namespace.)
const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

// Naked M-mode trap vector. A trap arrives at an arbitrary instruction boundary, so
// save a full integer-register frame (every GPR that can hold live caller state:
// ra, t0-t6, a0-a7, s0-s11; sp is managed here, gp/tp are fixed), dispatch to the
// MC handler with (mcause, mepc, mtval), restore, and `mret`. Saving the
// callee-saved registers too is belt-and-suspenders over the C ABI, so the
// interrupted context is preserved regardless of what the handler does. MC
// mtvec encodes the trap MODE in its low 2 bits, so the vector base MUST be 4-byte
// aligned (Direct mode = 0). With compressed instructions the toolchain only aligns
// functions to 2 bytes and MC has no function-alignment attribute, so the vector
// goes in its own `.text.mtrap` section that virt.ld pins to a 4-byte boundary.
#[naked]
#[section(".text.mtrap")]
export fn m_trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n csrr a0, mcause\n csrr a1, mepc\n csrr a2, mtval\n call handle_trap\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n mret"
    }
}

// Trigger an unexpected trap (an M-mode `ecall`, mcause 0xb) to exercise the
// fail-closed panic path: handle_trap diagnoses it (PANIC c=...) and halts rather
// than silently mret-ing.
fn raise_unexpected_trap() -> void {
    unsafe {
        asm opaque volatile {
            "ecall"
            clobber("memory")
        }
    }
}

export fn test_main() -> void {
    put_str("MC typed kernel booting\n");

    let ticks: u32 = kernel_tick_demo((&m_trap_vector) as usize, 3);
    put_str("TICKS ");
    put_dec(ticks as u64);
    console_putc(10); // '\n'
    if ticks >= 3 {
        put_str("TIMER-OK\n");
    } else {
        put_str("TIMER-FAIL\n");
    }

    raise_unexpected_trap();

    // Unreachable if the panic path halts as intended.
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode. `#[section(".text.start")]`
// pins `_start` there (virt.ld: `*(.text.start)` first, `ENTRY(_start)`). Set the
// stack and call into the kernel; never returns.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
