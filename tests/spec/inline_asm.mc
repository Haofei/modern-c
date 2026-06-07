// SPEC: section=23,I.15
// SPEC: milestone=inline-assembly
// SPEC: phase=sema,lower-c
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=E_UNSAFE_REQUIRED,E_PRECISE_ASM_CONTRACT,opaque-asm-lowering

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
