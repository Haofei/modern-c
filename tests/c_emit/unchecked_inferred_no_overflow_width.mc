// Differential fixture for inferred locals initialized from `unchecked.add/sub/mul`
// inside `#[unsafe_contract(no_overflow)]`. The C lowering must preserve the
// operand/result width instead of defaulting the inferred temporary/local to u32.

export fn noflow_u64_add_run(a: u64, b: u64) -> u64 {
    #[unsafe_contract(no_overflow)]
    {
        let inferred = unchecked.add(a, b);
        return inferred;
    }
}

export fn noflow_u64_sub_run(a: u64, b: u64) -> u64 {
    #[unsafe_contract(no_overflow)]
    {
        let inferred = unchecked.sub(a, b);
        return inferred;
    }
}

export fn noflow_u64_mul_run(a: u64, b: u64) -> u64 {
    #[unsafe_contract(no_overflow)]
    {
        let inferred = unchecked.mul(a, b);
        return inferred;
    }
}

export fn noflow_i64_sub_run(a: i64, b: i64) -> i64 {
    #[unsafe_contract(no_overflow)]
    {
        let inferred = unchecked.sub(a, b);
        return inferred;
    }
}

export fn unchecked_inferred_width_run() -> u32 {
    let add = noflow_u64_add_run(0x1_0000_0000, 0x27);
    let sub = noflow_u64_sub_run(0x1_0000_0040, 0x13);
    let mul = noflow_u64_mul_run(0x1_0000_0001, 2);
    let signed = noflow_i64_sub_run(-0x1_0000_0000, 7);

    if add != 0x1_0000_0027 { return 0; }
    if sub != 0x1_0000_002D { return 0; }
    if mul != 0x2_0000_0002 { return 0; }
    if signed != -0x1_0000_0007 { return 0; }
    return 1;
}
