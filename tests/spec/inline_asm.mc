// SPEC: section=23,I.15
// SPEC: milestone=inline-assembly
// SPEC: phase=sema,lower-c
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=E_UNSAFE_REQUIRED,E_PRECISE_ASM_CONTRACT,E_PRECISE_ASM_UNSUPPORTED,opaque-asm-lowering

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
        // EXPECT_ERROR: E_PRECISE_ASM_UNSUPPORTED
        asm precise volatile {
            "bsf %1, %0"
            clobber("cc")
        }
    }
}

fn reject_precise_asm_until_constraints_supported() -> void {
    #[unsafe_contract(precise_asm)]
    {
        unsafe {
            // EXPECT_ERROR: E_PRECISE_ASM_UNSUPPORTED
            asm precise volatile {
                "bsf %1, %0"
                clobber("cc")
            }
        }
    }
}
