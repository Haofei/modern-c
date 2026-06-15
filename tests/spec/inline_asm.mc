// SPEC: section=23,I.15
// SPEC: milestone=inline-assembly
// SPEC: phase=sema,lower-c
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=E_UNSAFE_REQUIRED,E_PRECISE_ASM_CONTRACT,E_ASM_UNKNOWN_REGISTER,E_ASM_ARCH_MIXED,E_ASM_REGISTER_CONFLICT,E_ASM_CLOBBER_CONFLICT,opaque-asm-lowering

fn accept_opaque_asm() -> void {
    unsafe {
        asm opaque volatile {
            "pause"
            clobber("memory")
        }
    }
}

fn accept_opaque_asm_default_memory() -> void {
    unsafe {
        asm opaque volatile {
            "cli"
        }
    }
}

fn reject_opaque_asm_outside_unsafe() -> void {
    // EXPECT_ERROR: E_UNSAFE_REQUIRED
    asm opaque volatile {
        "pause"
    }
}

fn reject_precise_asm_outside_contract() -> void {
    unsafe {
        // EXPECT_ERROR: E_PRECISE_ASM_CONTRACT
        asm precise volatile {
            "bsf %1, %0"
            clobber("cc")
        }
    }
}

// Precise asm (§23.2) is accepted inside a precise_asm unsafe contract: the
// compiler trusts the declared register/typed inputs, outputs, and clobbers.
fn accept_precise_asm(mask: u64) -> u64 {
    var idx: u64 = 0;
    #[unsafe_contract(precise_asm)]
    {
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

// Multiple inputs are wired in declared order (output `%0`, then inputs
// `%1`, `%2`), matching the template's positional operands. Operands are
// register-width (u64) so the lowering's `"r"` constraints type-check on any
// 64-bit target.
fn accept_precise_asm_multi(a: u64, b: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)]
    {
        unsafe {
            asm precise volatile {
                "mov %1, %0"
                out("rax") result: u64,
                in("rbx") a: u64,
                in("rcx") b: u64,
                clobber("cc")
            }
        }
    }
    return result;
}

// ===== precise-asm register/constraint verification (§23.2) =================
// The backends lower operands with generic `"r"` constraints and keep the named
// registers only as provenance — so the contract must *verify* the register facts:
// real registers, one architecture per block, and no register bound twice or
// clobbered while held by an operand (an unsupported constraint combination).

// Rejected: a register name that is not valid on any supported architecture.
fn reject_asm_unknown_register(x: u64) -> u64 {
    var out_val: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            // EXPECT_ERROR: E_ASM_UNKNOWN_REGISTER
            asm precise volatile {
                "nop"
                out("rax") out_val: u64,
                in("zmm99") x: u64
            }
        }
    }
    return out_val;
}

// Rejected: one block names registers from two different architectures
// (`rax` is x86-64, `a0` is RISC-V) — a precise-asm block targets one ISA.
fn reject_asm_arch_mixed(x: u64) -> u64 {
    var out_val: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            // EXPECT_ERROR: E_ASM_ARCH_MIXED
            asm precise volatile {
                "nop"
                out("rax") out_val: u64,
                in("a0") x: u64
            }
        }
    }
    return out_val;
}

// Rejected: the same register bound to two operands (output and input both `rax`).
fn reject_asm_register_conflict(x: u64) -> u64 {
    var out_val: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            // EXPECT_ERROR: E_ASM_REGISTER_CONFLICT
            asm precise volatile {
                "nop"
                out("rax") out_val: u64,
                in("rax") x: u64
            }
        }
    }
    return out_val;
}

// Rejected: a clobber names a register that is also an operand (`rax`).
fn reject_asm_clobber_conflict(x: u64) -> u64 {
    var out_val: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            // EXPECT_ERROR: E_ASM_CLOBBER_CONFLICT
            asm precise volatile {
                "nop"
                out("rax") out_val: u64,
                in("rbx") x: u64,
                clobber("rax")
            }
        }
    }
    return out_val;
}
