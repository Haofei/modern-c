// kernel/arch/riscv64/csr — raw machine-mode CSR access via inline assembly.
// (QEMU `virt -bios none` boots in M-mode, so the kernel uses the machine CSRs:
// mtvec, mstatus.MIE, mie.MTIE.) This is the only riscv64-specific file the hart
// typestate needs; an ARM port provides the same operations over its own system
// registers. Each is a thin, audited wrapper so the typed layer never open-codes
// assembly.

const MSTATUS_MIE: usize = 0x8;  // machine global interrupt enable (mstatus.MIE)
const MIE_MTIE: usize = 0x80;    // machine timer interrupt enable (mie.MTIE)

// Set the machine trap vector base (mtvec) to `addr` (direct mode).
export fn write_trap_vector(addr: usize) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw mtvec, %0"
                in("r") addr: usize
            }
        }
    }
}

// The current machine trap vector base.
export fn read_trap_vector() -> usize {
    var v: usize = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrr %0, mtvec"
                out("r") v: usize
            }
        }
    }
    return v;
}

// Enable interrupts globally (set mstatus.MIE).
export fn enable_interrupts_global() -> void {
    let bit: usize = MSTATUS_MIE;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrs mstatus, %0"
                in("r") bit: usize
            }
        }
    }
}

// Disable interrupts globally (clear mstatus.MIE).
export fn disable_interrupts_global() -> void {
    let bit: usize = MSTATUS_MIE;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrc mstatus, %0"
                in("r") bit: usize
            }
        }
    }
}

// Enable the machine timer interrupt source (set mie.MTIE).
export fn enable_timer_interrupt() -> void {
    let bit: usize = MIE_MTIE;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrs mie, %0"
                in("r") bit: usize
            }
        }
    }
}
