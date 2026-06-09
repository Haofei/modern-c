#[no_lang_trap]
fn pick_const(xs: [4]u8) -> u8 {
    return xs.const_get<2>();
}

fn pick_checked(xs: [4]u8, i: usize) -> u8 {
    return xs[i];
}
