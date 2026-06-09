fn unchecked_add_inside_contract(a: u32, b: u32) -> u32 {
    var x: u32 = 0;
    #[unsafe_contract(no_overflow)]
    {
        x = unchecked.add(a, b);
    }
    return x;
}

fn checked_after_contract(xs: []const u32) -> u32 {
    var sum: u32 = 0;
    #[unsafe_contract(no_overflow)]
    {
        for x in xs {
            sum = unchecked.add(sum, x);
        }
    }

    let after: u32 = sum + 0;
    return after;
}

fn noalias_contract_region(p: *mut u8, n: usize) -> void {
    #[unsafe_contract(noalias)]
    {
        let a = compiler.assume_noalias_unchecked(p, n);
        unsafe {
            raw.store<u8>(a, 1);
        }
    }

    unsafe {
        raw.store<u8>(p, 2);
    }
}
