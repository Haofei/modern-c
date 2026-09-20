move struct Guard { id: u32 }
fn make_guard() -> Guard { return .{ .id = 1 }; }
#[drop]
fn close_guard(g: *mut Guard) -> void { g.id = 0; }
fn return_guard() -> Guard {
    var g = make_guard();
    return move g;
}
