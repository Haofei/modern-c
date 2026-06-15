// Per-architecture precise-asm register vocabularies (§23.2), split by target.
//
// This fixture is `mcc check`-only: the templates use each ISA's own mnemonics and
// registers, which cannot be host-assembled through the C emit sweep, so the value
// here is that sema *recognizes and accepts* each architecture's register names and
// rejects nothing. The companion `asm-targets-test.sh` asserts `mcc check` passes
// with zero diagnostics. The negative side (unknown register, mixed architectures,
// register/clobber conflicts) lives in tests/spec/inline_asm.mc.

// ----- x86-64: rax/rbx/rcx + the flags pseudo-clobber -----
fn x86_bitscan(mask: u64) -> u64 {
    var idx: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "bsf %1, %0"
                out("rax") idx: u64,
                in("rbx") mask: u64,
                clobber("cc")
            }
        }
    }
    return idx;
}

fn x86_three_operand(a: u64, b: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mov %1, %0\n\tadd %2, %0"
                out("rax") result: u64,
                in("rbx") a: u64,
                in("rcx") b: u64,
                clobber("cc")
            }
        }
    }
    return result;
}

// ----- RISC-V 64: ABI register names a0/a1/a2, memory clobber -----
fn riscv_add(a: u64, b: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "add %0, %1, %2"
                out("a0") result: u64,
                in("a1") a: u64,
                in("a2") b: u64,
                clobber("memory")
            }
        }
    }
    return result;
}

fn riscv_temp_regs(x: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mv %0, %1"
                out("t0") result: u64,
                in("t1") x: u64
            }
        }
    }
    return result;
}

// ----- AArch64: w-registers and the shared x-registers -----
fn aarch64_move(x: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mov %w0, %w1"
                out("w0") result: u64,
                in("w1") x: u64,
                clobber("cc")
            }
        }
    }
    return result;
}

// Shared x-registers (`x0..x30`) and `sp` are accepted on either 64-bit ISA without
// pinning the block to one — they unify with any architecture-specific register.
fn shared_x_registers(a: u64, b: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "add %0, %1, %2"
                out("x0") result: u64,
                in("x1") a: u64,
                in("x2") b: u64
            }
        }
    }
    return result;
}
