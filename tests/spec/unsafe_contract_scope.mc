// SPEC: section=1.3,E.3,J
// SPEC: milestone=unsafe-contract-scoping
// SPEC: phase=sema,mir,lower-ir
// SPEC: expect=compile_error,pass,inspect
// SPEC: check=E_UNCHECKED_OUTSIDE_CONTRACT,contract_region,metadata-contained

fn reject_unchecked_add_outside_contract(a: u32, b: u32) -> u32 {
    // EXPECT_ERROR: E_UNCHECKED_OUTSIDE_CONTRACT
    return unchecked.add(a, b);
}

fn allow_unchecked_add_inside_contract(xs: []const u32) -> u32 {
    var sum: u32 = 0;

    #[unsafe_contract(no_overflow)]
    {
        for x in xs {
            sum = unchecked.add(sum, x);
        }
    }

    // EXPECT: MIR contains contract_region kind=no_overflow around unchecked add.
    // EXPECT: contract-derived overflow metadata does not persist beyond end_contract_region.
    let after: u32 = sum + 0;
    return after;
}

fn reject_unchecked_add_inside_noalias_contract(a: u32, b: u32) -> u32 {
    #[unsafe_contract(noalias)]
    {
        // EXPECT_ERROR: E_UNCHECKED_OUTSIDE_CONTRACT
        return unchecked.add(a, b);
    }
}

fn noalias_contract_region(p: *mut u8, n: usize) -> void {
    #[unsafe_contract(noalias)]
    {
        let a = compiler.assume_noalias_unchecked(p, n);
        unsafe {
            raw.store<u8>(a, 1);
        }
    }

    // EXPECT: noalias metadata from the contract is stripped or ended at region exit.
    unsafe {
        raw.store<u8>(p, 2);
    }
}

fn reject_noalias_assume_inside_no_overflow_contract(p: *mut u8, n: usize) -> void {
    #[unsafe_contract(no_overflow)]
    {
        // EXPECT_ERROR: E_UNCHECKED_OUTSIDE_CONTRACT
        let a = compiler.assume_noalias_unchecked(p, n);
    }
}
