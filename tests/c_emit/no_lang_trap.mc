#[no_lang_trap]
fn allow_wrapping_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a + b;
}

#[no_lang_trap]
fn allow_wrapping_neg(a: wrap<u32>) -> wrap<u32> {
    return -a;
}

#[no_lang_trap]
fn allow_saturating_add(a: sat<u32>, b: sat<u32>) -> sat<u32> {
    return a + b;
}

#[no_lang_trap]
fn allow_call_no_lang_trap_fn(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return allow_wrapping_add(a, b);
}

#[no_lang_trap]
fn allow_raw_many_offset_deref(p: [*]const u8, i: usize) -> u8 {
    unsafe {
        return p.offset(i).*;
    }
}
