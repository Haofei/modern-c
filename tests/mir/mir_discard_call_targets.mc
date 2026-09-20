move struct Guard { id: u32 }
#[drop]
fn close_guard(g: *mut Guard) -> void {
    g.id = 0;
}
fn discard_values(value: Guard) -> void {
    drop(value);
    unsafe { forget_unchecked(value); }
}
fn discard_plain(value: u32) -> void {
    drop(value);
    unsafe { forget_unchecked(value); }
}
