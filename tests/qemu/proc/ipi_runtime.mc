// Bare-metal riscv64 M-mode IPI runtime — in PURE MC (no C). The all-MC replacement
// for kernel/arch/riscv64/ipi_runtime.c.
//
// Two harts boot. Hart 1 installs a machine-software-interrupt handler and arms MSIE,
// then waits. Hart 0 raises an IPI on hart 1 (via the MC CLINT helper in
// tests/qemu/proc/ipi_demo.mc, linked beside this object), hart 1 traps, clears +
// counts it, and hart 0 confirms delivery.

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register
const RT_FINISHER: usize = 0x0010_0000; // SiFive test finisher
const RT_FINISHER_HALT: u32 = 0x5555;
const RT_MIE_MSIE: usize = 0x8;             // machine software interrupt enable (mie)
const RT_MSTATUS_MIE: usize = 0x8;          // global machine interrupt enable (mstatus)
const RT_CAUSE_MSI: u64 = 0x8000_0000_0000_0003; // interrupt | machine software interrupt

fn uputc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(RT_UART_THR), c);
    }
}

fn uputs(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        uputc(b);
        i = i + 1;
    }
}

// MC entry points (tests/qemu/proc/ipi_demo.mc).
extern fn ipi_send(target: u32) -> void;
extern fn ipi_clear(hart: u32) -> void;
extern fn ipi_arrive() -> u32;
extern fn ipi_count() -> u32;
extern fn hart1_set_ready() -> void;
extern fn hart1_is_ready() -> u32;

// Called from the trap vector with mcause in a0. A delivered IPI is a machine
// software interrupt: deassert it (clear MSIP) then count it.
export fn ipi_handler(mcause: u64) -> void {
    if mcause == RT_CAUSE_MSI {
        var h: usize = 0;
        #[unsafe_contract(precise_asm)] {
            unsafe {
                asm precise volatile {
                    "csrr %0, mhartid"
                    out("r") h: usize
                }
            }
        }
        ipi_clear(h as u32);
        ipi_arrive();
    }
}

#[naked]
#[section(".text.mtrap")]
export fn ipi_trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -64\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd a0, 32(sp)\n sd a1, 40(sp)\n sd a2, 48(sp)\n sd a3, 56(sp)\n csrr a0, mcause\n call ipi_handler\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld a0, 32(sp)\n ld a1, 40(sp)\n ld a2, 48(sp)\n ld a3, 56(sp)\n addi sp, sp, 64\n mret"
    }
}

export fn hart_main(hartid: u64) -> void {
    if hartid == 1 {
        // Arm machine software interrupts and wait to be poked.
        let vec: usize = (&ipi_trap_vector) as usize;
        let msie: usize = RT_MIE_MSIE;
        let mie_bit: usize = RT_MSTATUS_MIE;
        #[unsafe_contract(precise_asm)] {
            unsafe {
                asm precise volatile {
                    "csrw mtvec, %0"
                    in("r") vec: usize
                }
                asm precise volatile {
                    "csrs mie, %0"
                    in("r") msie: usize
                }
                asm precise volatile {
                    "csrs mstatus, %0"
                    in("r") mie_bit: usize
                }
            }
        }
        hart1_set_ready();
        while true {
            unsafe { asm opaque volatile { "wfi" } }
        }
    }

    // Hart 0: wait until hart 1 is armed, send it an IPI, await delivery.
    while hart1_is_ready() == 0 {
    }
    ipi_send(1);
    while ipi_count() < 1 {
    }
    uputs("IPI-OK\n");
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {
        unsafe { asm opaque volatile { "wfi" } }
    }
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "csrr a0, mhartid\n la t0, _stack_top\n slli t1, a0, 12\n sub sp, t0, t1\n call hart_main\n 1: wfi\n j 1b"
    }
}
