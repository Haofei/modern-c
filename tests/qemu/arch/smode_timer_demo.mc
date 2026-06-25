// REAL S-mode timer-interrupt delivery under OpenSBI — in PURE MC (no C). The
// RISC-V analogue of the x86 LAPIC-timer proof, and the keystone for moving the
// kernel's flat bare-metal runtimes off C onto MC's inline-asm + `#[naked]`.
//
// A flat S-mode kernel (booted by REAL OpenSBI at 0x80200000, satp=0 Bare mode)
// programs the SBI TIME extension to fire an S-mode timer interrupt, enables
// S-mode timer interrupts, and counts ticks in its trap handler — re-arming the
// timer each tick. It parks the hart in `wfi` between ticks, so a no-delivery bug
// HANGS into the QEMU timeout (NOT a busy poll that would mask a missing
// interrupt). After TARGET real interrupts have been delivered and serviced, it
// reports `SMODE-TIMER TICKS=<n>` + `SMODE-TIMER-OK` over the SBI console and
// shuts down.
//
// Pure S-mode (NO U-mode): every trap is taken with sstatus.SPP=1, so the trap
// vector does NOT swap sscratch — it saves a full integer frame on the current
// kernel stack, dispatches, restores, and `sret`s.

import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_console.mc";

// QEMU virt timebase is 10 MHz, so 1_000_000 time units ~= 0.1 s/tick. TARGET=3
// ticks => ~0.3 s, comfortably inside the QEMU timeout.
const INTERVAL: u64 = 1000000;
const TARGET: u64 = 3;

// scause for an S-mode timer interrupt: interrupt bit (63) set + cause 5.
const SCAUSE_S_TIMER: u64 = 0x8000_0000_0000_0005;

// sie.STIE = bit 5 (S-mode timer interrupt enable); sstatus.SIE = bit 1.
const SIE_STIE: u64 = 0x20;
const SSTATUS_SIE: u64 = 0x2;

// The tick counter, written from the timer ISR and read from the main loop.
global g_ticks: u64 = 0;

// Architectural S-mode time source. Under OpenSBI the CLINT mtime MMIO is NOT
// mapped into S-mode (a direct load faults), so read the `time` CSR (rdtime),
// which OpenSBI keeps in sync with the 10 MHz QEMU virt mtimer.
fn rdtime() -> u64 {
    var t: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "rdtime %0"
                out("t0") t: u64
            }
        }
    }
    return t;
}

// Set the S-mode trap vector base (stvec) in Direct mode (low 2 bits = 0).
fn write_stvec(addr: usize) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw stvec, %0"
                in("t0") addr: usize
            }
        }
    }
}

// Set bits in sie (S-mode interrupt-enable register).
fn set_sie(bits: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrs sie, %0"
                in("t0") bits: u64
            }
        }
    }
}

// Set bits in sstatus (here: the global S-mode interrupt enable SIE).
fn set_sstatus(bits: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrs sstatus, %0"
                in("t0") bits: u64
            }
        }
    }
}

// Park the hart until an interrupt is pending (idle, not spinning).
fn wait_for_interrupt() -> void {
    unsafe {
        asm opaque volatile {
            "wfi"
            clobber("memory")
        }
    }
}

// S-mode trap handler, called by the naked vector with scause in a0. On an
// S-timer interrupt: count it and re-arm (which also clears STIP). On ANY other
// cause (a real fault), fail closed: report and shut down — do NOT loop (a fault
// loop would otherwise spin forever).
export fn s_timer_trap(scause: u64) -> void {
    if scause == SCAUSE_S_TIMER {
        g_ticks = g_ticks + 1;
        sbi_set_timer(rdtime() + INTERVAL);
        return;
    }
    sbi_puts("SMODE-TIMER-BAD scause=");
    put_hex(scause);
    sbi_putchar(10); // '\n'
    sbi_shutdown();
    while true {}
}

// Naked S-mode trap vector. Pure S-mode kernel: every trap comes from S-mode
// (sstatus.SPP=1), so NO sscratch swap — save a full integer frame on the current
// kernel stack, pass scause to `s_timer_trap`, restore, `sret`. MC functions are
// already >=4-byte aligned, so stvec's Direct mode (low 2 bits = 0) is satisfied
// without an explicit alignment attribute.
#[naked]
export fn s_trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n csrr a0, scause\n call s_timer_trap\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n sret"
    }
}

export fn s_entry(_hartid: u64, _dtb: u64) -> void {
    sbi_puts("smode-timer: S-mode under OpenSBI\n");

    // stvec in Direct mode (low 2 bits = 0): all traps vector to s_trap_vector.
    write_stvec((&s_trap_vector) as usize);

    // Arm the first deadline BEFORE enabling, so the interrupt is pending the
    // moment we open the gate.
    sbi_set_timer(rdtime() + INTERVAL);

    // Enable S-timer interrupts (sie.STIE), then global S-interrupts (sstatus.SIE).
    // OpenSBI delegates the S-timer to S-mode by default (mideleg), so the
    // SBI-programmed timer raises an S-mode interrupt here.
    set_sie(SIE_STIE);
    set_sstatus(SSTATUS_SIE);

    // Park the hart until each interrupt fires. A no-delivery bug hangs here into
    // the QEMU timeout rather than busy-polling g_ticks (which would mask a missing
    // interrupt).
    while g_ticks < TARGET {
        wait_for_interrupt();
    }

    sbi_puts("SMODE-TIMER TICKS=");
    put_dec(g_ticks);
    sbi_putchar(10); // '\n'
    sbi_puts("SMODE-TIMER-OK\n");
    sbi_shutdown();
    while true {}
}

// OpenSBI enters in S-mode at 0x80200000 with a0=hartid, a1=dtb. Set the stack
// but do NOT clobber a0/a1 before the call. `#[section(".text.boot")]` pins
// `_start` to 0x80200000 (sbi.ld: `KEEP(*(.text.boot))` first), where OpenSBI
// jumps regardless of the ELF entry symbol.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
