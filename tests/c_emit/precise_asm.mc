// Precise inline assembly (§23.2) lowers to GCC/Clang extended asm. The compiler
// trusts the declared register/typed inputs, outputs, and clobbers: outputs are
// numbered first (`%0..`) then inputs, so the MC template's positional operands
// line up. Outputs bind their named local lvalue (`"=r"(local)`); inputs feed
// their value expression (`"r"(expr)`). Operands are register-width (u64) so the
// generic `"r"` constraints type-check on any 64-bit target.

fn find_first_set(mask: u64) -> u64 {
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

// Multiple inputs, multi-line template, and an output written back to a local.
fn combine(a: u64, b: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)]
    {
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

// Non-volatile precise asm with a single input and no clobbers.
fn double_it(x: u64) -> u64 {
    var out_val: u64 = 0;
    #[unsafe_contract(precise_asm)]
    {
        unsafe {
            asm precise {
                "lea (%1,%1), %0"
                out("rax") out_val: u64,
                in("rbx") x: u64
            }
        }
    }
    return out_val;
}
